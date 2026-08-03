# Proxy 直连层：API 与模型管理（P1xx/P2xx）

> 返回主文档：[E2E 测试用例总览](e2e-case-desc.md)

## API 与模型管理（P1xx/P2xx）

### P101 — 模型 CRUD（注册/列表/删除）

**目的**: 验证模型注册、列表、删除全生命周期。

| 步骤 | 操作 |
|---|---|
| 1 | 注册模型 A（无 run_id → 默认 DEFAULT） |
| 2 | 注册模型 B（run_id: test-run-001） |
| 3 | 列出所有模型 |
| 4 | 删除模型 A（run_id: default） |
| 5 | 删除模型 B（run_id: test-run-001） |
| 6 | 再次列出所有模型 |

**验收标准**: 所有注册/删除返回 HTTP 200 且 `status=success`；模型 A 的 `run_id=DEFAULT`；注册后列表包含两个模型；删除后列表不包含任一模型。

---

### P102 — PANGU 格式集成（model_name,run_id）

**目的**: 测试 PANGU 的 `{model_name},{run_id}` 模型参数格式。

| 步骤 | 操作 |
|---|---|
| 1 | 注册模型（run_id: run-p102） |
| 2 | 非流式请求，使用 `model: "Qwen3.6-27B,run-p102"` |
| 3 | 流式请求，使用相同格式 |
| 4 | 删除模型 |

**验收标准**: 注册成功；非流式返回 `id` 和 `choices`；流式包含 `data:`、`choices`、`[DONE]` 且有多个 chunk；删除成功。

---

### P103 — 重复注册（幂等性）

**目的**: 验证同一模型注册两次是幂等的。

| 步骤 | 操作 |
|---|---|
| 1 | 注册模型（run_id: run-p103） |
| 2 | 再次注册同一模型 |

**验收标准**: 两次注册均返回 HTTP 200（或第二次 409 视为幂等）。

---

### P104 — 预设模型保护（不可删除）

**目的**: 验证 config.yaml 中的预设模型不能通过 API 删除。

| 步骤 | 操作 |
|---|---|
| 1 | 列出模型 → 确认预设模型存在 |
| 2 | 尝试删除预设模型（run_id 为空）→ 期望 404 |
| 3 | 尝试删除预设模型（run_id=app-001）→ 期望 404 |
| 4 | 再次列出模型 → 确认预设模型仍存在 |

**验收标准**: 两次删除均返回 HTTP 404；预设模型始终存在于列表中。

---

### P105 — 未注册模型

**目的**: 验证请求未注册模型时返回错误。

| 步骤 | 操作 |
|---|---|
| 1 | 向 `unregistered_model_xyz` 发送 Chat 请求 |

**验收标准**: 返回 HTTP 404 或 400（两者均可接受，具体状态码取决于后端实现方式）。

---

### P106 — 无效模型参数

**目的**: 验证模型参数校验。

| 步骤 | 操作 |
|---|---|
| 1 | 发送 `model=""` 请求 |
| 2 | 发送 `model=null` 请求 |
| 3 | 不传 model 字段 |

**验收标准**: 三种情况均返回 HTTP 422 或 400。

---

### P107 — 并发限流

**目的**: 验证 `max_concurrent_requests` 限制导致 HTTP 429。

| 步骤 | 操作 |
|---|---|
| 1 | 注册模型（run_id: run-p107） |
| 2 | 发送 20 个并发 Chat 请求 |
| 3 | 收集所有 HTTP 状态码 |

**验收标准**: 系统不崩溃；至少部分请求返回 429（限流触发）；至少部分请求返回 200。

---

### P201 — 参数透传（Direct 模式）

**目的**: 验证 OpenAI 参数和自定义 Header 在 Direct 模式下正确透传到后端，内部 Header 被拦截。

**前置条件**: Mock 推理服务器启动（端口 19990），Direct 模式模型注册。

| 步骤 | 操作 |
|---|---|
| 1 | 启动 Mock 服务器 |
| 2 | 注册 Direct 模式模型 |
| 3 | 非流式请求：`seed=42, n=1, stop=["\\n"], logprobs=true, top_logprobs=3, user=test-user` |
| 4 | 验证 Mock 接收到的参数 |
| 5 | 流式请求：`seed=99` |
| 6 | 验证流式参数 |
| 7 | 删除模型 |

**验收标准**:

| # | 断言 | 期望 |
|---|---|---|
| 1 | `seed` 透传 | `42`（Non-Stream）/ `99`（Stream） |
| 2 | `n` 透传 | `1` |
| 3 | `user` 透传 | `"test-user-passthrough"` |
| 4 | `logprobs` 被强制覆盖 | `1`（非用户的 `true`） |
| 5 | `x-sandbox-traj-id` 透传 | ✓ |
| 6 | `x-custom-header` 透传 | ✓ |
| 7 | `x-run-id` 不转发（内部 Header） | ✓ |
| 8 | `x-session-id` 不转发（内部 Header） | ✓ |

---

### P202 — 参数过滤（TITO 模式）

**目的**: 验证 TITO 模式下不兼容参数被过滤，兼容参数正常透传。

**前置条件**: Mock 服务器（端口 19991），TITO 模式模型注册。

| 步骤 | 操作 |
|---|---|
| 1 | 启动 Mock 服务器 |
| 2 | 注册 TITO 模型（含 tokenizer） |
| 3 | 发送请求：兼容参数（`seed=42, n=1, user`）+ 不兼容参数（`response_format, logit_bias`） |
| 4 | 验证 Mock 参数 |
| 5 | 删除模型 |

**验收标准**: `response_format` → NOT_FOUND（被过滤）；`logit_bias` → NOT_FOUND（被过滤）；`seed=42, n=1, user="tito-user"` 正常透传；`x-run-id`/`x-session-id` 不转发。

---

### P203 — Logprobs 强制覆盖与返回过滤

**目的**: 验证 Proxy 强制设置 `logprobs=1` 和 `return_token_ids=True`，从客户端响应中剥离，存储到轨迹中。

| 步骤 | 操作 |
|---|---|
| 1-5 | 非流式 5 种场景：无参数 / `logprobs=true` / `logprobs=5` / `return_token_ids=true` / 两者同时 |
| 6-10 | 流式相同 5 种场景 |
| 11 | 对每种：验证客户端响应和轨迹存储 |

**验收标准**: 客户端响应中无 `logprobs`、无 `token_ids`；轨迹 `raw_response` 中 `logprobs` 非空、`token_ids` 非空；流式所有 chunk 均无 logprobs/token_ids。

---

### P204 — chat_template_kwargs 透传与消费

**目的**: Direct 模式 kwargs 透传到后端；TITO 模式 kwargs 被 MessageConverter 消费，不出现在 completion 请求中。

| 步骤 | 操作 |
|---|---|
| **Part A** | Direct 模型：注册 → NS+Stream 发送含 kwargs 请求 → 验证 Mock 有 kwargs → 删除 |
| **Part B** | TITO 模型：注册 → NS+Stream 发送含 kwargs 请求 → 验证 Mock 无 kwargs → 删除 |

**验收标准**: Part A Mock 收到 `chat_template_kwargs`（含 `enable_thinking`）；Part B completion 请求中 NOT_FOUND；两者均返回 200。

---

### P108 — Processor 懒加载

**目的**: 验证模型配置在注册时存储，Processor 仅在首次请求时加载。

| 步骤 | 操作 |
|---|---|
| 1 | 注册 Direct 模型（run-lazy-001） |
| 2 | 首次请求（触发懒加载） |
| 3 | 第二次请求（命中 LRU 缓存） |
| 4 | 流式请求（验证缓存 Processor 支持流式） |
| 5 | 删除模型 |

**验收标准**: 所有请求返回 HTTP 200 且有 `choices`；流式响应包含 SSE `data:` 前缀。

---

### P109 — Processor LRU 缓存命中与访问排序

**目的**: 验证 5 个模型的 LRU 缓存管理、缓存命中与访问顺序。

| 步骤 | 操作 |
|---|---|
| 1 | 注册 5 个模型（run-lru-002-{1..5}） |
| 2 | 第一轮：请求全部 5 个（触发懒加载） |
| 3 | 第二轮：再次请求全部 5 个（应命中缓存） |
| 4 | 交替请求模型 1 和 5（3 轮，验证 LRU 访问顺序） |
| 5 | 删除全部 5 个模型 |

**验收标准**: 第一轮懒加载+请求成功；第二轮缓存命中+请求成功；交替请求全部成功。

---

### P110 — 预设模型懒加载

**目的**: 验证 config.yaml 预设模型在首次请求时懒加载，缓存命中，且不可被 API 删除。

| 步骤 | 操作 |
|---|---|
| 1 | 列出模型 → 确认预设存在 |
| 2 | 首次请求预设模型（触发懒加载） |
| 3 | 第二次请求（缓存命中） |
| 4 | 带 `run_id=app-001` 请求 |
| 5 | 尝试删除预设模型 → 期望 404 |

**验收标准**: 列表包含预设模型；首次请求成功（懒加载）；第二次成功；删除返回 404。

---

### P111 — LRU 逐出与重新加载

**目的**: 注册 35 个模型（超过 LRU 默认容量 32），验证逐出和重新加载机制。

| 步骤 | 操作 |
|---|---|
| 1 | 注册 35 个模型（run-lru-evict-{1..35}） |
| 2 | 第一轮：请求全部 35 个（填充缓存，触发逐出） |
| 3 | 重新请求模型 1-3（应已被逐出，验证重新加载） |
| 4 | 重新请求模型 33-35（应仍在缓存中） |
| 5 | 删除全部 35 个模型 |

**验收标准**: 所有 35 个注册成功；逐出模型（1-3）重新加载成功；缓存中模型（33-35）仍成功；所有 35 个删除成功。

---

### P205 — 自定义 Tool Parser

**目的**: 验证 `custom_parsers/tool_parsers/` 下的自定义 tool_parser 自动发现和加载。

| 步骤 | 操作 |
|---|---|
| 1 | 注册 TITO 模型（`tool_parser="test_tool_parser"`） |
| 2 | 发送含 `tools=[get_weather]` 的 Chat 请求 |
| 3 | 查询轨迹 |
| 4 | 删除模型 |

**验收标准**: 注册成功且 `tool_parser` 匹配；响应有 `tool_calls` 且 `function` 非空；轨迹 `count > 0` 且 `session_id` 匹配。

---

### P206 — 自定义 Reasoning Parser

**目的**: 验证 `custom_parsers/reasoning_parsers/` 下的自定义 reasoning_parser 自动发现和加载。

| 步骤 | 操作 |
|---|---|
| 1 | 注册 TITO 模型（`reasoning_parser="test_reasoning_parser"`） |
| 2 | 发送 Chat 请求（"Output exactly: The answer is 42."） |
| 3 | 查询轨迹 |
| 4 | 删除模型 |

**验收标准**: 注册成功且 `reasoning_parser` 匹配；`reasoning` 字段非空；轨迹 `count > 0`。

---

### P207 — TITO Token 模式冒烟（非流式）

**目的**: TITO 非流式模式基础功能验证 + response_ids 校验。

| 步骤 | 操作 |
|---|---|
| 1 | 注册 TITO 模型（无 parser） |
| 2 | 发送非流式请求 |
| 3 | 查询轨迹 |

**验收标准**: HTTP 200；轨迹 `response_ids` 长度 > 0。

---

### P208 — TITO Token 模式冒烟（流式）

**目的**: TITO 流式模式基础功能验证。

| 步骤 | 操作 |
|---|---|
| 1 | 注册 TITO 模型 |
| 2 | 发送流式请求 |

**验收标准**: 流式响应包含 `data:` 和 `[DONE]`。

---

### P209 — Direct 模式额外字段剥离

**目的**: DirectPipeline 下 vLLM 返回的 `routed_experts`（MoE 路由元数据）不暴露给客户端；r3offload 开启后轨迹中存为 marker。

| 步骤 | 操作 |
|---|---|
| 1 | 启动 Mock 服务，注册 Direct 模式模型 |
| 2 | 发送非流式/流式请求 |
| 3 | 查询轨迹验证 routed_experts 为 marker |

**验收标准**: 客户端响应不含 routed_experts；轨迹 raw_response 中为 marker，可回拉（闭环由 P502/P503 验证）。

---

### P210 — TITO 模式额外字段存储

**目的**: TokenPipeline(TITO) 下 `routed_experts` 不暴露给客户端；r3offload 开启后轨迹 token_response 中存为 marker。

| 步骤 | 操作 |
|---|---|
| 1 | 启动 Mock 服务，注册 TITO 模式模型 |
| 2 | 发送非流式/流式请求 |
| 3 | 查询轨迹验证 routed_experts 为 marker |

**验收标准**: 客户端响应不含 routed_experts；轨迹 token_response 中为 marker，可回拉（闭环由 P502/P503 验证）。

---

### P211 — 空 think 内容非流式场景

**目的**: 防止"模型推理输出 think 内容为空时 `</think>` 落入 content"的回归（非流式路径 openai_builder 对 `extract_reasoning` 返回值做 truthy 检查导致）。

| 步骤 | 操作 |
|---|---|
| 1 | 启动 Mock 服务（端口 19999），注册 TITO + reasoning_parser 模型（model 名含 `empty-think` 触发 Mock 返回 `<think></think>你好`） |
| 2 | 发送非流式请求 |
| 3 | 删除模型 |

**验收标准**: HTTP 200；响应 content 为 `你好`，且不含 `<think>`/`</think>` 标记。

---