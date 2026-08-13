# 流式场景自定义字段透传设计

> 版本: 1.1.0 (v2 — 整合 Oracle 对抗审查反馈)
> 日期: 2026-06-23
> 作者: Design Agent + Oracle Review

---

## 一、背景与问题

TrajProxy 在流式(SSE)场景下，将推理服务的响应存入数据库时，**推理服务返回的自定义字段未被完整保留**。

### 现状分析

| Pipeline | DB 字段 | 已知字段 | 自定义字段 |
|---|---|---|---|
| DirectPipeline | `raw_response` (JSON) | ✅ 完整 | ⚠️ 顶级✅ choice级❌ |
| TokenPipeline | `token_response` (JSON) | ⚠️ 部分 | ❌ 全部丢失 |

**已知字段** = 协议标准字段 + vLLM 扩展字段（`reasoning`、`stop_reason`、`token_ids`、`logprobs` 等）

---

## 二、需求目标

1. **DirectPipeline**: `raw_response` 保留推理服务返回的所有自定义字段（choice 级 + delta 级）
2. **TokenPipeline**: `token_response` 保留推理服务返回的所有自定义字段（顶级 + choice 级）

**约束**：
- 不修改数据库 schema（JSON 列天然支持）
- 不破坏 vLLM 对齐约束（变更在 Pipeline 层，不涉及 parser 内部）
- 不改变客户端可见的响应结构（自定义字段仅影响 DB 存储，不影响 forward）

---

## 三、设计概览

### 核心原则

1. **排除集驱动**：用模块级 `frozenset` 常量定义已知字段，不在排除集中的字段一律视为自定义字段
2. **已知字段优先**：自定义字段 **先合并**，已知字段 **后设置**，杜绝自定义字段覆盖已知字段
3. **`value is not None` 守卫**：null 值不入累积字典，防止后续 chunk 的 null 覆盖前一 chunk 的有效值
4. **"Last wins" 语义**：自定义字段使用 **最后值覆盖** 语义（非列表合并）
5. **独立常量**：两条 Pipeline 各有独立的排除集，互不干扰

---

## 四、详细设计

### 4.1 ProcessContext 新增字段

```python
# context.py — 新增流式累积字段

# DirectPipeline: 累积 choice 级 + delta 级自定义字段
stream_choice_extras: Optional[Dict[str, Any]] = None   # choice 层自定义字段（last wins）
stream_delta_extras: Optional[Dict[str, Any]] = None    # delta 层自定义字段（last wins）

# TokenPipeline: 累积顶级 + choice 级自定义字段
stream_infer_metadata: Optional[Dict[str, Any]] = None  # 顶级自定义字段（last wins）
stream_infer_choice_extras: Optional[Dict[str, Any]] = None  # choice 级自定义字段（last wins）
```

### 4.2 排除集常量定义

```python
# direct_pipeline.py — 模块级常量

# Direct Pipeline 已知 choice 级字段（排除 delta 本身）
# 这些字段有专用的累积逻辑，不应被透传机制覆盖
DIRECT_KNOWN_CHOICE_KEYS: frozenset[str] = frozenset({
    "index",          # 固定值 0
    "delta",          # delta 对象，单独处理
    "finish_reason",  # 流式结束标志
    "logprobs",       # 有专用的 extend/merge 逻辑
    "token_ids",      # 有专用的 extend 逻辑
    "stop_reason",    # vLLM 扩展，专用存储
})

# Direct Pipeline 已知 delta 级字段
# 这些字段在 _accumulate_stream_fields 中逐一处理
DIRECT_KNOWN_DELTA_KEYS: frozenset[str] = frozenset({
    "role",
    "content",
    "reasoning",
    "reasoning_content",
    "tool_calls",
    "function_call",
})
```

```python
# token_pipeline.py — 模块级常量

# Token Pipeline 已知顶级字段（choices 和 usage 单独处理，但排除集需包含它们）
TOKEN_KNOWN_TOP_KEYS: frozenset[str] = frozenset({
    "id",          # 由 pipeline 生成
    "object",      # 固定值
    "created",     # 由 pipeline 生成
    "model",       # 来自请求
    "choices",     # 单独处理
    "usage",       # 有专用捕获逻辑
})

# Token Pipeline 已知 choice 级字段（来自 /v1/completions 响应）
TOKEN_KNOWN_CHOICE_KEYS: frozenset[str] = frozenset({
    "text",            # 响应文本/token ID 字符串
    "token_ids",       # choice 级 token ID 列表
    "output_token_ids",  # vLLM 扩展
    "index",           # choice 索引
    "finish_reason",   # 结束原因
    "logprobs",        # 概率信息
    "tool_calls",      # 工具调用（流式 delta）
})
```

### 4.3 DirectPipeline 修改

#### `_accumulate_stream_fields()` — 新增 choice/delta 自定义字段捕获

```python
# 在现有 choice 处理逻辑之后，添加：

# 9. 捕获 choice 级自定义字段（排除已知字段，null 值跳过）
choice_extras = {
    k: v for k, v in choice.items()
    if k not in DIRECT_KNOWN_CHOICE_KEYS and v is not None
}
if choice_extras:
    if context.stream_choice_extras is None:
        context.stream_choice_extras = {}
    context.stream_choice_extras.update(choice_extras)

# 10. 捕获 delta 级自定义字段（排除已知字段，null 值跳过）
delta_extras = {
    k: v for k, v in delta.items()
    if k not in DIRECT_KNOWN_DELTA_KEYS and v is not None
}
if delta_extras:
    if context.stream_delta_extras is None:
        context.stream_delta_extras = {}
    context.stream_delta_extras.update(delta_extras)
```

#### `_finalize_stream()` — 合并顺序修正（Oracle Critical #1）

**关键修正**：自定义字段**先合并**（作为 base），已知字段**后设置**（作为 authoritative override）。

```python
# 构建 choice 字典
choice = {"index": 0}

# ① 先合并 delta 级自定义字段（作为 message 的 base）
message = {}
if context.stream_delta_extras:
    message.update(context.stream_delta_extras)

# ② 后设置已知 message 字段（authoritative — 覆盖同名自定义字段）
message["role"] = context.stream_role or "assistant"
message["content"] = context.response_text or (...)
message["annotations"] = None
message["audio"] = None
message["function_call"] = context.stream_function_call
message["refusal"] = None
# ... reasoning、tool_calls 等保持不变

choice["message"] = message

# ③ 先合并 choice 级自定义字段（作为 choice 的 base extras）
if context.stream_choice_extras:
    choice.update(context.stream_choice_extras)

# ④ 后设置已知 choice 字段（authoritative — 覆盖同名自定义字段）
choice["logprobs"] = context.stream_logprobs
choice["token_ids"] = context.stream_token_ids
choice["finish_reason"] = context.stream_finish_reason or "stop"
if context.stream_stop_reason is not None:
    choice["stop_reason"] = context.stream_stop_reason
```

### 4.4 TokenPipeline 修改

#### `_process_stream_chunk()` — 新增顶级/choice 级自定义字段捕获

**位置变更 (Oracle Major #4)**：usage 捕获移到 `is_stream_finished` 守卫 **外部**，每个 chunk 都检查。

```python
# 在函数开头（现有逻辑之前），捕获顶级自定义字段
if context.stream_infer_metadata is None:
    context.stream_infer_metadata = {}
for key, value in infer_chunk.items():
    if key not in TOKEN_KNOWN_TOP_KEYS and value is not None:
        context.stream_infer_metadata[key] = value

# 捕获 usage（每个非 null chunk，last wins — 移到 is_stream_finished 守卫外）
if "usage" in infer_chunk and infer_chunk["usage"]:
    if context.token_response is None:
        context.token_response = {}
    context.token_response["usage"] = infer_chunk["usage"]

# 捕获 choice 级自定义字段
if "choices" in infer_chunk and infer_chunk["choices"]:
    infer_choice = infer_chunk["choices"][0]
    choice_extras = {
        k: v for k, v in infer_choice.items()
        if k not in TOKEN_KNOWN_CHOICE_KEYS and v is not None
    }
    if choice_extras:
        if context.stream_infer_choice_extras is None:
            context.stream_infer_choice_extras = {}
        context.stream_infer_choice_extras.update(choice_extras)

# ... 现有逻辑（InferResponseParser.parse_stream_chunk 等）保持不变 ...

# 删除原有 finish chunk 内的 usage 捕获（已移至上方）
# if InferResponseParser.is_stream_finished(infer_chunk):
#     ... finish_reason 逻辑保留 ...
#     # 删除: if "usage" in infer_chunk: ...
```

#### `_finalize_stream()` — 合并自定义字段到 token_response

```python
# 在 context.token_response 构建完成后（约 line 737 之后），添加：

# 合并顶级自定义字段（先 base，后已知字段）
if context.stream_infer_metadata:
    for k, v in context.stream_infer_metadata.items():
        context.token_response.setdefault(k, v)

# 合并 choice 级自定义字段到已构建的 choice
if context.stream_infer_choice_extras and "choices" in context.token_response:
    for k, v in context.stream_infer_choice_extras.items():
        context.token_response["choices"][0].setdefault(k, v)
```

**注意**：TokenPipeline 使用 `setdefault` 而非 `update`，因为已构建的 choice/top 字段是 pipeline 根据累积数据计算的权威值，自定义字段仅作为补充。

---

## 五、数据流对比

### DirectPipeline 流式（修改后）

```
推理服务 SSE chunk
    │
    ├── 顶级字段 → stream_response_metadata（已有，last wins） ✅
    ├── usage      → stream_usage_full（已有，last wins） ✅
    ├── choice     → 已知字段逐一累积（已有） ✅
    │            → 未知字段 → stream_choice_extras（新增，last wins） 🆕
    └── delta      → 已知字段逐一累积（已有） ✅
                 → 未知字段 → stream_delta_extras（新增，last wins） 🆕
    
    ─── 流结束 ────────────────────────────────────────
    
    _finalize_stream:
      message = delta_extras ∪ {known message fields}    ← base → override
      choice  = choice_extras ∪ {known choice fields}    ← base → override
      raw_response = metadata ∪ {choices, usage}         ← base → override
```

### TokenPipeline 流式（修改后）

```
推理服务 SSE chunk（/v1/completions 格式）
    │
    ├── 顶级字段 → stream_infer_metadata（新增，last wins） 🆕
    ├── usage      → token_response.usage（新增，每 chunk 检查） 🆕
    ├── choice     → 已知字段由 pipeline 累积（已有） ✅
    │            → 未知字段 → stream_infer_choice_extras（新增，last wins） 🆕
    └── parser     → 工具调用、推理内容（已有） ✅
    
    ─── 流结束 ────────────────────────────────────────
    
    _finalize_stream:
      token_response = {} ∪ usage ∪ choices(已知) ∪ metadata(setdefault) ∪ choice_extras(setdefault)
```

---

## 六、Oracle 审查发现与处置

| # | 严重级别 | 发现 | 处置 |
|---|---|---|---|
| 1 | 🔴 Critical | merge 顺序反转导致自定义字段覆盖已知字段 | 改为 base→override 顺序（§4.3 ①②③④） |
| 2 | 🔴 Critical | delta 级自定义字段未捕获 | 新增 `stream_delta_extras` 及 `DIRECT_KNOWN_DELTA_KEYS`（§4.3） |
| 3 | 🟡 Major | choice 级缺少 `value is not None` 守卫 | 所有累积字典均加入守卫（§4.3/§4.4） |
| 4 | 🟡 Major | `token_ids`/`stop_reason` 未入排除集 | 显式列入排除集常量（§4.2） |
| 5 | 🟡 Major | "last wins" 对列表类型语义不正确 | 文档化限制：自定义字段列表仅保留最后值（§七.3） |
| 6 | 🟡 Major | TokenPipeline usage 仅在 finish chunk 捕获 | 移至 `is_stream_finished` 守卫外（§4.4） |
| 7 | 🟡 Major | 命名不一致 | 改用 `stream_infer_metadata` / `stream_infer_choice_extras`（§4.1） |
| 8 | 🟡 Major | `prompt_token_ids` choice 级不存在 | 不在 choice 排除集中列出（§4.2 TOKEN_KNOWN_CHOICE_KEYS） |
| 9 | 🟢 Minor | 安全：内部诊断字段可能入库 | 文档化说明，当前不引入 blocklist（§七.2） |
| 10 | ℹ️ Info | vLLM 对齐无影响 | 确认变更在 Pipeline 层，不涉及 parser（§七.1） |
| 11 | ℹ️ Info | 性能开销可忽略 | 每 chunk 约 ~10 次 dict lookup，< 1ms（§七.4） |
| 12 | ℹ️ Info | Schema 无需变更 | JSON 列天然支持（§七.5） |

---

## 七、影响分析

### 7.1 vLLM 对齐合规性

变更范围全部在 TrajProxy Pipeline 层和 ProcessContext，不涉及：
- `vllm_compat/tool_parsers/`（工具解析器）
- `vllm_compat/reasoning_parsers/`（推理解析器）
- Parser 方法签名
- Parser 内部状态管理

**结论：不违反 vLLM 对齐约束。**

### 7.2 安全影响

推理服务返回的所有字段（含自定义字段）将被持久化到 JSON 列。如果推理服务返回内部诊断信息（worker ID、routing metadata 等），这些信息会被存储。

**当前决策**：不引入字段黑名单。原因：
- 推理服务是受信任的内部组件
- 现有 `stream_response_metadata` 已捕获所有顶级自定义字段
- 引入黑名单增加维护成本，且难以覆盖所有情况
- 如需脱敏，后续可通过配置化黑名单实现

### 7.3 已知限制

**"Last wins" 语义对列表类型字段的局限性**：
如果推理服务在流式 delta 中返回数组类型的自定义字段，且这些字段跨 chunk 累积（类似 content 拼接），"last wins" 会丢失中间值。

这是有意的设计取舍：
- 无法预知自定义字段的累积语义
- 已知列表字段（content、token_ids、logprobs）有专用累积逻辑
- 自定义字段属于罕见场景，过度工程化得不偿失

**文档化声明**：自定义字段采用 "last wins" 语义；如需其他语义，应将其注册为已知字段并编写专用累积逻辑。

### 7.4 性能影响

- 每 chunk 新增 ~10 次 dict key 查找 + dict assignment
- 4 个新增累积字典，最大各 ~10 entries
- 10,000 chunks 场景下总增量 < 1ms

### 7.5 Schema 影响

`request_details_active` 表中 `raw_response` 和 `token_response` 均为 JSON 类型，支持任意 JSON 结构。无需 DDL 变更。

### 7.6 非流式路径（无影响）

| 路径 | 当前行为 | 需要修改 |
|---|---|---|
| DirectPipeline 非流式 | `raw_response` = 推理服务原始响应（完整） | ❌ 无需 |
| TokenPipeline 非流式 | `token_response` = 推理服务原始响应（完整） | ❌ 无需 |

---

## 八、任务拆分

### Phase 1: Context 与常量（基础）

| 任务 | 文件 | 描述 |
|---|---|---|
| T1.1 | `context.py` | 新增 4 个流式累积字段 + docstring |
| T1.2 | `direct_pipeline.py` | 定义排除集常量 `DIRECT_KNOWN_CHOICE_KEYS`、`DIRECT_KNOWN_DELTA_KEYS` |
| T1.3 | `token_pipeline.py` | 定义排除集常量 `TOKEN_KNOWN_TOP_KEYS`、`TOKEN_KNOWN_CHOICE_KEYS` |

### Phase 2: DirectPipeline 改造

| 任务 | 文件 | 描述 |
|---|---|---|
| T2.1 | `direct_pipeline.py` | `_accumulate_stream_fields` 末尾新增 choice/delta extras 捕获 |
| T2.2 | `direct_pipeline.py` | `_finalize_stream` 改造 choice 构建顺序（base→override） |

### Phase 3: TokenPipeline 改造

| 任务 | 文件 | 描述 |
|---|---|---|
| T3.1 | `token_pipeline.py` | `_process_stream_chunk` 头部新增顶级/choice/usage 捕获 |
| T3.2 | `token_pipeline.py` | 移除 finish chunk 内的 usage 捕获逻辑 |
| T3.3 | `token_pipeline.py` | `_finalize_stream` 新增 metadata/choice_extras 合并 |

### Phase 4: 测试

| 任务 | 文件 | 描述 |
|---|---|---|
| T4.1 | `tests/` | DirectPipeline: choice 级自定义字段 last-wins |
| T4.2 | `tests/` | DirectPipeline: delta 级自定义字段被捕获 |
| T4.3 | `tests/` | DirectPipeline: null 值被跳过 |
| T4.4 | `tests/` | DirectPipeline: 已知字段不被自定义字段覆盖 |
| T4.5 | `tests/` | TokenPipeline: 顶级自定义字段被保留 |
| T4.6 | `tests/` | TokenPipeline: usage-only finish chunk 正确处理 |
| T4.7 | `tests/` | TokenPipeline: choice 级自定义字段被保留 |
| T4.8 | `tests/` | 非流式回归测试（DirectPipeline + TokenPipeline） |

---

## 九、变更历史

| 版本 | 日期 | 变更说明 |
|---|---|---|
| 1.0.0 | 2026-06-23 | 初始版本（未经审查） |
| 1.1.0 | 2026-06-23 | 整合 Oracle 对抗审查反馈：修复 merge 顺序、新增 delta 级捕获、移动 usage 捕获位置、显式排除集常量、命名规范化 |
