# 数据库设计

> **导航**: [文档中心](../../README.md) | [Store 模块](../modules/store.md) | [优化方案](optimization.md)

TrajProxy 使用 PostgreSQL 存储模型配置和请求轨迹记录。

请求轨迹采用**元数据+详情分离**架构：元数据表长期保留轻量统计信息，详情表只存近期大字段（按月分区），过期后归档到外部 JSONL+GZIP 文件。

---

## 表结构概览

| 表名 | 说明 |
|------|------|
| `model_registry` | 模型配置注册表 |
| `request_metadata` | 请求轨迹元数据（长期保留） |
| `request_details_active` | 请求轨迹详情（近期大字段，按月分区） |

### 架构关系

```
┌─────────────────────────────────────────────────┐
│               request_metadata                    │
│          （元数据表，长期保留）                     │
│   unique_id, session_id, model, tokens, ...      │
│   archive_location: NULL | "2026_03.jsonl.gz"    │
└─────────────────────┬───────────────────────────┘
                      │ archive_location IS NULL
                      ▼
┌─────────────────────────────────────────────────┐
│          request_details_active                   │
│        （详情表，按月分区，只存近期）              │
│   大字段: messages, raw_request, ...              │
└─────────────────────────────────────────────────┘
                      │ archive_location NOT NULL
                      ▼
┌─────────────────────────────────────────────────┐
│             外部存储 (JSONL+GZIP)                 │
│          /archives/{run_id}/{session_id}.jsonl.gz │
└─────────────────────────────────────────────────┘
```

---

## model_registry 表

存储动态注册的模型配置。

### 表结构

```sql
CREATE TABLE model_registry (
    id SERIAL PRIMARY KEY,
    run_id TEXT,                          -- 运行ID，NULL表示全局模型
    model_name TEXT NOT NULL,              -- 模型名称
    url TEXT NOT NULL,                     -- 推理服务 URL
    api_key TEXT NOT NULL,                 -- API 密钥
    tokenizer_path TEXT,                   -- Tokenizer 路径（可选，直接转发模式不需要）
    token_in_token_out BOOLEAN DEFAULT FALSE,  -- 是否启用 Token 模式
    tool_parser TEXT NOT NULL DEFAULT '',  -- 工具解析器名称
    reasoning_parser TEXT NOT NULL DEFAULT '', -- 推理解析器名称
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT unique_run_model UNIQUE (run_id, model_name)
);
```

### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | SERIAL | 是 | 主键 |
| `run_id` | TEXT | 否 | 运行ID，NULL 表示全局模型，用于多租户场景 |
| `model_name` | TEXT | 是 | 模型名称，请求时使用 |
| `url` | TEXT | 是 | 推理服务 URL |
| `api_key` | TEXT | 是 | API 密钥 |
| `tokenizer_path` | TEXT | 否 | Tokenizer 路径（本地路径或 HuggingFace 名称），直接转发模式不需要 |
| `token_in_token_out` | BOOLEAN | 否 | 是否启用 Token-in-Token-out 模式，默认 false |
| `tool_parser` | TEXT | 否 | 工具解析器名称（如 `deepseek_v3`） |
| `reasoning_parser` | TEXT | 否 | 推理解析器名称（如 `deepseek_r1`） |
| `updated_at` | TIMESTAMP | 否 | 最后更新时间 |

### 索引

| 索引名 | 字段 | 说明 |
|--------|------|------|
| `model_registry_run_id_idx` | `run_id` | 按运行ID查询 |
| `model_registry_model_name_idx` | `model_name` | 按模型名查询 |
| `model_registry_updated_at_idx` | `updated_at DESC` | 按更新时间查询 |

### 唯一约束

`(run_id, model_name)` 组合唯一，允许不同 run_id 下存在同名模型。

---

## ModelConfig 数据类

**文件：** `traj_proxy/store/models.py`

```python
@dataclass
class ModelConfig:
    """模型配置数据类"""
    url: str
    api_key: str
    tokenizer_path: Optional[str] = None  # 可选，直接转发模式下不需要
    run_id: Optional[str] = None           # 运行ID，None 表示全局模型
    model_name: str = ""
    token_in_token_out: bool = False
    tool_parser: str = ""                  # 工具解析器名称
    reasoning_parser: str = ""             # 推理解析器名称
    updated_at: Optional[datetime] = None
```

---

## request_metadata 表

存储请求轨迹的元数据（统计信息），长期保留，不随归档删除。

> **设计规范**：参见 [ID 设计规范](../modules/identifiers.md)

### 表结构

```sql
CREATE TABLE request_metadata (
    id BIGSERIAL PRIMARY KEY,
    unique_id TEXT NOT NULL UNIQUE,
    request_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    run_id TEXT,                      -- 运行ID，独立存储
    model TEXT NOT NULL,

    -- 统计信息（长期保留）
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    cache_hit_tokens INTEGER DEFAULT 0,
    processing_duration_ms FLOAT,

    -- 时间字段
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- 错误信息
    error TEXT,

    -- 归档追踪（NULL = 活跃, 非空 = 已归档到外部文件）
    archive_location TEXT,
    archived_at TIMESTAMP WITH TIME ZONE
);
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `unique_id` | TEXT UNIQUE | 全局唯一标识，格式: `{session_id},{request_id}` |
| `request_id` | TEXT | 请求 ID |
| `session_id` | TEXT | 会话 ID，存储原始值 |
| `run_id` | TEXT | 运行 ID，独立存储，可选 |
| `model` | TEXT | 使用的模型名称 |
| `prompt_tokens` | INTEGER | 输入 Token 数 |
| `completion_tokens` | INTEGER | 输出 Token 数 |
| `total_tokens` | INTEGER | 总 Token 数 |
| `cache_hit_tokens` | INTEGER | 缓存命中的 Token 数 |
| `processing_duration_ms` | FLOAT | 请求处理时长（毫秒） |
| `error` | TEXT | 错误信息 |
| `archive_location` | TEXT | NULL=活跃详情表, 非空=已归档到外部文件 |
| `archived_at` | TIMESTAMPTZ | 归档时间 |

### session_id 和 run_id 说明

> **变更说明**：`session_id` 存储原始值，不再自动补充 `run_id` 前缀；`run_id` 独立存储。

| 字段 | 存储 | 示例 |
|------|------|------|
| `session_id` | 原始值 | `task-123` |
| `run_id` | 独立存储 | `run_001` |

**查询示例**：
```sql
-- 查询特定 run_id 的所有轨迹
SELECT * FROM request_metadata WHERE run_id = 'run_001';

-- 查询特定会话的轨迹
SELECT * FROM request_metadata WHERE session_id = 'task-123';

-- 查询特定 run_id 和会话的轨迹
SELECT * FROM request_metadata WHERE run_id = 'run_001' AND session_id = 'task-123';
```

### 索引

| 索引名 | 字段 | 说明 |
|--------|------|------|
| `request_metadata_session_id_idx` | `session_id` | 按会话查询 |
| `request_metadata_run_id_idx` | `run_id` | 按 run_id 查询 |
| `request_metadata_start_time_idx` | `start_time DESC` | 按时间倒序查询 |
| `request_metadata_archive_location_idx` | `archive_location` | 部分索引（WHERE NOT NULL），查找已归档记录 |

---

## request_details_active 表

存储请求轨迹的详情大字段，按月分区，只保留近期数据。过期数据通过归档进程按 run_id 粒度 DELETE + UPDATE，空月分区 DETACH + DROP，零 VACUUM 压力。

### 表结构

```sql
CREATE TABLE request_details_active (
    id BIGSERIAL,
    unique_id TEXT NOT NULL
        REFERENCES request_metadata(unique_id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Tokenizer
    tokenizer_path TEXT,

    -- 阶段1: OpenAI Chat 格式
    messages JSON NOT NULL,
    raw_request JSON,
    raw_response JSON,

    -- 阶段2: 文本推理格式（Token模式）
    text_request JSON,
    text_response JSON,

    -- 阶段3: Token 推理格式（Token模式）
    prompt_text TEXT,
    token_ids INTEGER[],
    token_request JSON,
    token_response JSON,

    -- 输出数据
    response_text TEXT,
    response_ids INTEGER[],

    -- 完整对话
    full_conversation_text TEXT,
    full_conversation_token_ids INTEGER[],

    -- 错误详情
    error_traceback TEXT,

    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
```

### 分区管理

- 自动创建当前月和下月分区（启动时 + 归档脚本执行时）
- 分区命名：`request_details_active_YYYY_MM`
- 默认分区：`request_details_active_default`（捕获不属于任何月分区的数据，归档时会 DETACH → 清空 → ATTACH）
- 归档时 DETACH + DROP 分区（瞬间完成，无 VACUUM 压力）

### 字段分组说明

#### 请求阶段字段

| 阶段 | 字段 | 说明 |
|------|------|------|
| 阶段1 | `raw_request`, `raw_response` | OpenAI 格式原始请求/响应（所有模式都有） |
| 阶段2 | `text_request`, `text_response` | 文本推理格式（仅 Token 模式） |
| 阶段3 | `token_request`, `token_response` | Token 推理格式（仅 Token 模式） |

#### Token 相关字段

| 字段 | 说明 |
|------|------|
| `prompt_text` | 文本格式的 prompt（仅 Token 模式） |
| `token_ids` | 输入 Token ID 数组（仅 Token 模式） |
| `response_text` | 响应文本 |
| `response_ids` | 输出 Token ID 数组（仅 Token 模式） |

#### 缓存相关字段

| 字段 | 说明 |
|------|------|
| `full_conversation_text` | 完整对话文本（用于前缀匹配缓存） |
| `full_conversation_token_ids` | 完整对话 Token ID（用于前缀匹配缓存） |

### 索引

| 索引名 | 字段 | 说明 |
|--------|------|------|
| `request_details_active_unique_id_idx` | `unique_id` | 按唯一标识查询（JOIN 用） |

---

## RequestRecord 数据类

**文件：** `traj_proxy/store/models.py`

```python
@dataclass
class RequestRecord:
    """请求轨迹记录数据类"""
    unique_id: str
    request_id: str
    session_id: str
    model: str
    messages: List[Any]
    run_id: Optional[str] = None  # 运行ID，独立存储
    tokenizer_path: Optional[str] = None

    # 阶段1: OpenAI Chat 格式
    raw_request: Optional[Any] = None
    raw_response: Optional[Any] = None

    # 阶段2: 文本推理格式（Token模式）
    text_request: Optional[Any] = None
    text_response: Optional[Any] = None

    # 阶段3: Token 推理格式（Token模式）
    prompt_text: Optional[str] = None
    token_ids: Optional[List[int]] = None
    token_request: Optional[Any] = None
    token_response: Optional[Any] = None

    # 输出数据
    response_text: Optional[str] = None
    response_ids: Optional[List[int]] = None

    # 完整对话
    full_conversation_text: Optional[str] = None
    full_conversation_token_ids: Optional[List[int]] = None

    # 元数据
    start_time: Optional[datetime] = None
    end_time: Optional[datetime] = None
    processing_duration_ms: Optional[float] = None

    # 统计信息
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None
    total_tokens: Optional[int] = None
    cache_hit_tokens: int = 0

    # 错误信息
    error: Optional[str] = None
    error_traceback: Optional[str] = None

    # 创建时间
    created_at: Optional[datetime] = None

    # 归档追踪
    archive_location: Optional[str] = None      # NULL=活跃详情表, 非空=已归档
    archived_at: Optional[datetime] = None
```

---

## ProcessContext 数据类

**文件：** `traj_proxy/proxy_core/context.py`

ProcessContext 贯穿整个请求处理流程，包含输入数据、中间处理数据和输出结果。

> **完整字段定义**参见 [架构文档 - ProcessContext 数据结构](../architecture.md#process-context)（权威来源）。
>
> **ID 设计细节**参见 [ID 设计规范](../modules/identifiers.md)。

本文件不重复列出全部字段。数据流向见下节。

### 数据流向说明

**直接转发模式：**
```
raw_request → 推理服务 → raw_response
```

**Token 模式：**
```
raw_request → text_request → token_request → 推理服务 → token_response → text_response → raw_response
```

---

## 模型同步机制

> **完整架构图、Payload 格式、配置项**参见 [架构文档 - 十四、模型同步机制](../architecture.md#model-sync)（权威来源）。

TrajProxy 使用 **LISTEN/NOTIFY** + 定期全量兜底实现跨 Worker 的模型配置实时同步。

---

## 数据库初始化

容器启动时自动执行 `scripts/entrypoint.sh` 中的初始化逻辑：

1. 创建数据库（如果不存在）
2. 创建 `model_registry` 表和索引
3. 创建 `request_metadata` 表和索引
4. 创建 `request_details_active` 分区表、当月分区和索引

幂等执行，可重复运行。

---

## 归档机制

独立进程 `traj_archiver` 通过 Ray Worker 并发架构归档过期详情数据，详细设计见 [归档机制](archive.md)。

### 归档流程

```
协调器:
  1. 查找过期 run_id (MAX(created_at) < retention_days 阈值)
  2. 逐 run 查询 session 列表
  3. 动态分发给 Ray Worker 并发执行
  4. 收集结果 → run 级 DELETE + UPDATE 同事务
  5. 清理空月分区

Worker (每个 session):
  1. 新建 DB 连接，DECLARE CURSOR 流式读取
  2. 写 .jsonl.gz 文件
  3. 上传到存储后端 (本地/S3/CSB)
  4. 返回 {"records": int, "file": str}
```

### 归档配置

独立配置文件 `configs/archiver.yaml`:

```yaml
archive:
  retention_days: 30             # 活跃详情保留天数
  poll_interval: 3600            # 轮询间隔 (秒)
  num_workers: 1                 # Ray Worker 进程数，默认 1 (顺序)
  compress: true                 # 是否 gzip 压缩
  storage_path: "/data/archives" # 本地模式：归档文件目录
  local_temp_path: "/tmp/archives" # S3 模式：临时导出目录
```

### 调度器特性

- 独立进程，与核心业务 `traj_proxy` 零耦合
- 轮询模式，固定间隔执行
- 失败后等待 5 分钟重试
- 启动命令: `python -m traj_archiver`
- 状态查询: `get_status()` 返回 Worker 数量、运行状态和统计

---

## 查询示例

### 查询特定会话的活跃轨迹

```sql
SELECT m.unique_id, m.model, m.start_time, m.total_tokens,
       d.prompt_text, d.response_text
FROM request_metadata m
JOIN request_details_active d ON m.unique_id = d.unique_id
WHERE m.session_id = 'task_001'
  AND m.archive_location IS NULL
ORDER BY m.start_time DESC
LIMIT 100;
```

### 查询特定 run_id 的所有轨迹

```sql
SELECT unique_id, session_id, model, start_time, total_tokens
FROM request_metadata
WHERE run_id = 'run_001'
ORDER BY start_time DESC;
```

### 查询会话元数据（含活跃+已归档）

```sql
SELECT unique_id, model, start_time, total_tokens, archive_location
FROM request_metadata
WHERE session_id = 'task_001'
ORDER BY start_time DESC;
```

### 统计查询（跨全时段）

```sql
SELECT
    model,
    COUNT(*) as total_requests,
    SUM(total_tokens) as total_tokens,
    AVG(processing_duration_ms) as avg_duration_ms
FROM request_metadata
GROUP BY model
ORDER BY total_requests DESC;
```

### 按 run_id 统计

```sql
SELECT
    run_id,
    COUNT(*) as request_count,
    SUM(total_tokens) as total_tokens
FROM request_metadata
GROUP BY run_id;
```

### 查询缓存命中率

```sql
SELECT
    model,
    SUM(cache_hit_tokens)::float / NULLIF(SUM(prompt_tokens), 0) as cache_hit_rate
FROM request_metadata
GROUP BY model;
```

### 查询已注册模型

```sql
SELECT model_name, url, token_in_token_out, tool_parser, reasoning_parser, updated_at
FROM model_registry
ORDER BY model_name;
```
