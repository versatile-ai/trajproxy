# route_experts 大字段卸载设计文档

> 版本: 1.0.0
> 日期: 2026-06-30
> 导航: [文档中心](../../README.md) | [数据库设计](../data/schema.md) | [Store 模块](../modules/store.md)

> **⚠️ 生产部署警示（必读）**
>
> 本期**未实现清理任务**（设计文档十四.1 预留）。`enabled=true` 开启后：
> - `r3_blob_refs` 表持续增长，无回收机制（`expires_at` 字段写入但无消费方）
> - Local 后端磁盘文件、CSB 对象持续堆积，无删除
> - `status='uploading'` 的孤儿行（上传失败 / task cancel / worker crash）永久留驻
>
> **生产环境开启 `enabled=true` 前，必须先实现清理任务**（扫描 `expires_at < now()` 的行，
> 删除 blob + ref 行）。否则表膨胀与磁盘满会导致生产事故。
>
> 同时注意 `GET /records/{request_id}` 返回的 `routed_experts` 从原始大对象变为 marker，
> 所有消费 client 必须能识别 `{"_offloaded": true, ...}` 格式，属对外契约变更。

> **命名约定**（务必区分）：
> - **业务字段名 `routed_experts`**：infer 端返回的 JSON key（过去式），位于 `choices[0].routed_experts`。实现代码、mock、e2e 均用此名。
> - **特性名 / 配置段名 `route_experts`**：本项目对该卸载特性的内部命名，体现在配置段 `route_experts_offload`、`blob_key_prefix`、文件名、类名 `RouteExperts*`、方法名 `get_route_experts()`、API 路径 `.../route_experts`。不影响业务 JSON。
>
> 下方正文凡指代 **choices[0] 里的 JSON key** 时均用 `routed_experts`；凡指代特性 / 配置 / 路径时用 `route_experts`。

---

## 一、背景与问题

### 1.1 问题

推理响应中的 `routed_experts` 字段（位于 `choices[0].routed_experts`）体量极大，峰值可达 **500 GB/小时**。该字段当前随 `raw_response` / `token_response` 以 JSON 形式写入 `request_details_active` 表，带来以下风险：

- WAL 暴涨、checkpoint 阻塞、buffer pool 抖动
- `request_details_active` 分区膨胀速度远超归档清理周期
- 多节点并发写入大字段加剧锁竞争
- 该字段属于"使用后即丢弃"的临时数据，无长期留存价值

### 1.2 需求

- 将 `routed_experts` 从 PG 存储路径中剥离，卸载到外部对象存储（华为 CSB / 本地盘）
- PG 仅保留轻量引用行
- client 回拉 `routed_experts` 时**可绕过 TrajProxy 直接访问存储**（小时级时延）
- 本期不实现清理任务，但 schema 预留 `consumed_at` / `expires_at` 供未来扩展

---

## 二、设计目标与约束

### 2.1 设计目标

| 目标 | 含义 |
|------|------|
| **开关化** | `route_experts_offload.enabled` 配置控制，默认 `false` |
| **关闭时零影响** | Pipeline 代码路径、`RequestRepository` 行为、现有端点返回值与当前完全一致 |
| **非补丁式** | 不往 `_store_trajectory` / `process()` / `_finalize_stream()` 里塞 if/else；新逻辑封装为独立组件，通过组合注入 |
| **异步上传** | 上传 fire-and-forget，不阻塞推理响应（小时级回拉时延下成立） |

### 2.2 约束

| 约束 | 说明 |
|------|------|
| R3 字段 | `routed_experts`，位于 `choices[0].routed_experts` |
| DirectPipeline 取值路径 | `context.raw_response["choices"][0]["routed_experts"]` |
| TokenPipeline 取值路径 | `context.token_response["choices"][0]["routed_experts"]` |
| 回拉时延 | 小时级，上传异步可行 |
| 存储后端 | 华为 CSB + 本地盘，配置切换 |
| CSB 凭证 | client 持有自己的 app_token，TrajProxy 不暴露自身凭证 |
| Local 挂载 | 部署侧保证 TrajProxy 与 client 共享同一挂载点 |
| 清理任务 | 本期不实现，schema 预留字段 |
| 消费标记 | 本期不标记 consumed，避免阻断二次回拉且无清理收益 |

---

## 三、架构设计

### 3.1 Decorator 模式包裹 RequestRepository

```
                     ┌─────────────────────────────────────────┐
                     │  Worker (composition root)              │
                     │                                         │
                     │  enabled=false:                         │
                     │    repo = RequestRepository(pool)        │  ← 原样，零影响
                     │                                         │
                     │  enabled=true:                          │
                     │    inner   = RequestRepository(pool)     │
                     │    blob    = create_blob_storage(cfg)    │
                     │    refRepo = R3RefRepository(pool)       │
                     │    repo = OffloadingRepository(          │
                     │        inner, blob, refRepo, cfg         │  ← 透明包裹
                     │    )                                     │
                     └────────────────┬────────────────────────┘
                                      │
                                      ▼
                     Pipeline 拿到的就是 repo（不知道是否被包裹）
                                      │
                                      ▼
                     BasePipeline._store_trajectory()
                       → await repo.insert(context, ...)   ← 唯一调用点
```

### 3.2 为什么选 Decorator 而非 Pipeline 注入 Collaborator

| 维度 | Decorator 包裹 Repository | Pipeline 注入 Offloader |
|------|---------------------------|-------------------------|
| Pipeline 代码改动 | **零** | 需加 `if self._offloader:` |
| Processor / ProcessorManager 改动 | **零** | 需透传构造参数 |
| 关闭时影响 | **绝对零**（裸 repo） | 有空 check |
| 开关位置 | 单点（Worker 组装处） | 散在 DI 链 |
| 符合"非补丁式" | ✅ | ⚠️ |

Decorator 让 Pipeline / Processor / ProcessorManager **完全不动**，开关集中在 Worker 组装处一行。

### 3.3 整体流程

```
[Client POST /v1/chat/completions]
  → routes.py 生成 request_id
  → Processor → Pipeline.process() / process_stream()
  → 构造 context.raw_response / context.token_response  ← routed_experts 在此
  → BasePipeline._store_trajectory()
        │
        ├─ OffloadingRepository.insert(context):
        │     1. 抽 routed_experts 到临时变量（不改 context）
        │     2. INSERT r3_blob_refs (status='uploading')  ← 若失败，跳过卸载
        │     3. asyncio.create_task(blob.put + ref.mark_ready)  ← 火后即忘
        │     4. context.*.choices[0]["routed_experts"] = marker  ← 原位替换
        │     5. inner.insert(context)  ← PG 存的是轻量 marker
        │
  → 返回响应给 client（含 marker，client 据此直访存储）

[Background task: 上传]
  → blob.put(blob_key, data)
  → ref.mark_ready(request_id)
  → 失败：日志告警，留 uploading，未来清理回收

[Client 直访存储（小时级）]
  → CSB：client 用自己的 app_token → 三步认证 → GET object
  → Local：client open(access_path/blob_key)  ← 共享挂载

[Client 经 TrajProxy fallback（可选）]
  → GET /trajectories/{session_id}/records/{request_id}/route_experts
  → 查 ref → 流式返回
```

---

## 四、组件设计

### 4.1 BlobStorage（接口 + 两个实现）

文件：`traj_proxy/store/blob_storage.py`（新建）

```python
class BlobStorage(ABC):
    """外部对象存储抽象。"""

    @abstractmethod
    async def put(self, key: str, data: bytes) -> None: ...

    @abstractmethod
    async def get_streaming(self, key: str) -> AsyncIterator[bytes]: ...

    @abstractmethod
    async def delete(self, key: str) -> None: ...  # 幂等

    @abstractmethod
    async def exists(self, key: str) -> bool: ...


class CSBBlobStorage(BlobStorage):
    """华为 CSB 存储。照搬 traj_archiver/csb_storage.py 三步认证模式。"""
    # endpoint resolve → bucket auth → PUT/GET


class LocalDiskBlobStorage(BlobStorage):
    """本地盘存储。写 {write_path}/{key}，流式读用文件流。"""


def create_blob_storage(config: dict) -> BlobStorage:
    """工厂：backend=csb → CSBBlobStorage；backend=local → LocalDiskBlobStorage。"""
```

**不 import `traj_archiver`**（架构解耦），但 CSB 实现对齐 `traj_archiver/csb_storage.py` 的三步流程，保持一致性。

### 4.2 R3RefRepository

文件：`traj_proxy/store/r3_ref_repository.py`（新建）

严格对齐 `RequestRepository` 的 psycopg3 + `AsyncConnectionPool` + `transaction()` + `dict_row` 模式：

```python
class R3RefRepository:
    def __init__(self, pool: AsyncConnectionPool): ...

    async def insert_ref(
        self, request_id: str, blob_key: str, backend: str,
        size_bytes: int, expires_at: datetime,
    ) -> None: ...

    async def get_for_fetch(self, request_id: str) -> dict | None:
        """SELECT ... FOR UPDATE，供 fallback 端点用。"""

    async def mark_ready(self, request_id: str) -> None: ...

    async def mark_consumed(self, request_id: str) -> None:
        """预留，本期不调用。"""

    async def fetch_expired_for_cleanup(
        self, limit: int = 100,
    ) -> list[dict]:
        """预留，本期不调用。供未来清理任务用。"""
```

### 4.3 OffloadingRepository（Decorator）

文件：`traj_proxy/store/offloading_repository.py`（新建）

```python
class OffloadingRepository:
    """包裹 RequestRepository，透明卸载 routed_experts。

    关闭时 Worker 直接用裸 RequestRepository，此类不参与。
    """

    def __init__(
        self,
        inner: RequestRepository,
        blob: BlobStorage,
        ref_repo: R3RefRepository,
        backend: str,          # "csb" | "local"
        marker_config: dict,   # 构造响应 marker 所需的 access 侧参数
        ttl_hours: int,
    ): ...

    async def insert(
        self, context: ProcessContext, tokenizer_path: str, run_id: str,
    ) -> None:
        # 1. 抽 routed_experts（不改 context）
        re_data, source_field = self._extract(context)
        if re_data is None:
            return await self._inner.insert(context, tokenizer_path, run_id)

        # 2. 生成 blob_key
        blob_key = self._make_key(run_id, context.session_id, context.request_id)

        # 3. 插引用行（失败则跳过卸载，退化原行为）
        try:
            await self.ref_repo.insert_ref(
                context.request_id, blob_key, self.backend,
                size_bytes=len(re_data_serialized),
                expires_at=now() + timedelta(hours=self.ttl_hours),
            )
        except Exception:
            logger.warning("r3 ref insert failed, skip offloading")
            return await self._inner.insert(context, tokenizer_path, run_id)

        # 4. fire-and-forget 上传
        asyncio.create_task(self._upload(blob_key, re_data, context.request_id))

        # 5. 原位替换为 marker
        self._replace_with_marker(context, source_field, blob_key)

        # 6. delegate
        return await self._inner.insert(context, tokenizer_path, run_id)

    # 其他方法（get_record_detail 等）→ 直接 delegate 给 self._inner
```

**insert 顺序的失败安全性**：

| 步骤 | 失败后果 | 处理 |
|------|----------|------|
| 1. 抽取（不改 context） | 无影响 | 跳过卸载 |
| 2. 插引用行 | context 未改，routed_experts 仍在 | 退化原行为，PG 存大字段 |
| 3. fire-and-forget 上传 | ref 留 uploading，blob 缺失 | 日志告警，TTL 回收 |
| 4. 替换 marker | 已有 ref 行，marker 正确 | 正常 |
| 5. inner.insert | ref 在，blob 在上传，轨迹未存 | client 回拉得 404（轨迹查不到），ref 孤儿 TTL 回收 |

**关键原则**：ref insert 失败 → 不 strip → 退化原行为。任一步失败都保证 state 一致。

### 4.4 _extract 与 _replace_with_marker

```python
def _extract(
    self, context: ProcessContext,
) -> tuple[dict | None, str | None]:
    """先查 token_response（TITO），再查 raw_response（Direct）。"""
    for attr in ("token_response", "raw_response"):
        data = getattr(context, attr, None)
        if (
            data
            and isinstance(data.get("choices"), list)
            and data["choices"]
            and "routed_experts" in data["choices"][0]
        ):
            return data["choices"][0]["routed_experts"], attr
    return None, None


def _replace_with_marker(
    self, context: ProcessContext, source_field: str, blob_key: str,
) -> None:
    """原位替换 routed_experts 为直访 marker。"""
    data = getattr(context, source_field)
    data["choices"][0]["routed_experts"] = self._build_marker(blob_key)


def _build_marker(self, blob_key: str) -> dict:
    if self.backend == "csb":
        return {
            "_offloaded": True,
            "backend": "csb",
            "location": {
                "endpoint": self.marker_config["endpoint"],
                "bucket": self.marker_config["bucket"],
                "key": blob_key,
            },
        }
    else:  # local
        access_path = self.marker_config["access_path"]
        return {
            "_offloaded": True,
            "backend": "local",
            "location": {
                "path": f"{access_path}/{blob_key}",
            },
        }
```

---

## 五、数据模型

### 5.1 新表 r3_blob_refs

追加到 `dockers/compose/scripts/entrypoint.sh`（与现有建表同处，`CREATE TABLE IF NOT EXISTS` 幂等）：

```sql
CREATE TABLE IF NOT EXISTS public.r3_blob_refs (
    request_id   TEXT PRIMARY KEY,
    blob_key     TEXT NOT NULL,
    backend      TEXT NOT NULL,                        -- csb | local
    status       TEXT NOT NULL DEFAULT 'uploading',    -- uploading | ready | consumed
    size_bytes   BIGINT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    ready_at     TIMESTAMPTZ,                          -- 上传完成时间
    consumed_at  TIMESTAMPTZ,                          -- 预留：回拉消费时间
    expires_at   TIMESTAMPTZ NOT NULL                  -- = created_at + ttl，未来清理用
);

CREATE INDEX IF NOT EXISTS idx_r3_status_ready
    ON public.r3_blob_refs (expires_at)
    WHERE status IN ('uploading', 'ready');

CREATE INDEX IF NOT EXISTS idx_r3_status_consumed
    ON public.r3_blob_refs (consumed_at)
    WHERE status = 'consumed';
```

**现有表不改**：`request_metadata` / `request_details_active` / `model_registry` 完全不动。routed_experts 的 marker 自然存在 `request_details_active.raw_response` / `token_response` 的 JSON 里，无需新列。

### 5.2 与现有归档机制的关系

| 维度 | 归档机制（现有） | route_experts 卸载（本特性） |
|------|------------------|------------------------------|
| 触发 | traj_archiver 定时批量 | 请求时 inline |
| 数据去向 | S3/CSB/Local 永久归档 | CSB/Local 临时存储，TTL 回收 |
| PG 状态 | `request_metadata.archive_location` | `r3_blob_refs` 独立表 |
| 生命周期 | 30 天保留后归档 | 小时级，使用后清理 |
| 表交互 | 无 | 无（独立表，不影响归档扫描） |

两套机制完全独立，互不干扰。

---

## 六、配置

### 6.1 config.yaml 新增段

追加到 `configs/config.yaml`：

```yaml
route_experts_offload:
  enabled: false                    # 总开关，默认关
  ttl_hours: 2                      # expires_at = created_at + ttl
  blob_key_prefix: "route_experts"  # 对象 key 前缀

  backend: "local"                  # csb | local

  csb:
    # ---- write 侧（TrajProxy 用）----
    app_token: ""                   # 或 env CSB_APP_TOKEN
    bucket: "trajproxy-r3"
    # ---- access 侧（拼进响应 marker 给 client）----
    endpoint: "https://csb.example.com"

  local:
    # ---- write 侧 ----
    write_path: "/data/r3"          # TrajProxy 容器内写路径
    # ---- access 侧 ----
    access_path: "/mnt/shared/r3"   # 拼进响应给 client 的路径（共享挂载点）
    # 留空则默认 = write_path
```

### 6.2 环境变量覆盖

对齐现有 env 覆盖模式：

| 环境变量 | 覆盖字段 |
|----------|----------|
| `R3_OFFLOAD_ENABLED` | `enabled` |
| `R3_BACKEND` | `backend` |
| `R3_TTL_HOURS` | `ttl_hours` |
| `CSB_APP_TOKEN` | `csb.app_token` |
| `R3_LOCAL_WRITE_PATH` | `local.write_path` |
| `R3_LOCAL_ACCESS_PATH` | `local.access_path` |

### 6.3 write_path vs access_path

| 字段 | 视角 | 用途 |
|------|------|------|
| `write_path` | TrajProxy 容器 | 写文件/对象时的根路径 |
| `access_path` | client | 响应 marker 里给 client 的路径前缀 |

两者可能因挂载点不同而不同（容器内 `/data/r3` ↔ client 侧 `/mnt/shared/r3`）。若同路径，`access_path` 留空默认等于 `write_path`。

---

## 七、响应 Marker 格式

### 7.1 CSB 后端

```json
"routed_experts": {
    "_offloaded": true,
    "backend": "csb",
    "location": {
        "endpoint": "https://csb.example.com",
        "bucket": "trajproxy-r3",
        "key": "route_experts/{run_id}/{session_id}/{request_id}.json"
    }
}
```

### 7.2 Local 后端

```json
"routed_experts": {
    "_offloaded": true,
    "backend": "local",
    "location": {
        "path": "/mnt/shared/r3/route_experts/{run_id}/{session_id}/{request_id}.json"
    }
}
```

### 7.3 设计说明

- **不放 `status` 字段**：响应返回时上传总在进行中（fire-and-forget），放 `status:"uploading"` 会误导 client 以为需要轮询。小时级回拉时上传早完成，client 直接取，404 就退避重试。
- **`_offloaded` 前缀下划线**：明确标记这是卸载占位符，不是原始数据。
- **marker 存入 PG JSON**：随 `raw_response` / `token_response` 自然存储，无需新列。现有 `GET /trajectories/{session_id}/records/{request_id}` 端点返回的响应里会带 marker，client 可从该端点或原始响应获取定位信息。

---

## 八、直访模型

### 8.1 CSB 直访

```
TrajProxy 写：
  用 app_token 走三步认证（endpoint resolve → bucket auth → PUT）
  → 写入 bucket/trajproxy-r3/key

响应 marker：
  {endpoint, bucket, key}

Client 直访：
  用 client 自己的 app_token 走同一套三步认证 → GET object
```

**前提**：client 持有自己的 CSB app_token。TrajProxy 不暴露自身凭证。

### 8.2 Local 直访

```
TrajProxy 写：
  写文件 {write_path}/{blob_key}

响应 marker：
  {path: access_path + "/" + blob_key}

Client 直访：
  open(path)  ← 依赖共享挂载（NFS / PV / hostPath）
```

**前提**：部署侧保证 `access_path` 在 client 侧可见。这是部署约束，不是代码问题。

### 8.3 blob_key 格式

```
{blob_key_prefix}/{run_id}/{session_id}/{request_id}.json
```

按 run_id / session_id 分层，便于按 run 或 session 浏览/批量操作。

---

## 九、TrajProxy Fallback 端点

### 9.1 定位

**可选 fallback**，非主路径。用途：
- client 直访失败时回退（存储临时不可达）
- 状态查询（上传是否完成）
- 调试

### 9.2 端点定义

```
GET /trajectories/{session_id}/records/{request_id}/route_experts
```

- 路由：`traj_proxy/serve/routes.py`（新增）
- 业务方法：`traj_proxy/proxy_core/provider.py`（新增 `get_route_experts()`）

### 9.3 行为

```
1. ref = ref_repo.get_for_fetch(request_id)   # SELECT ... FOR UPDATE
2. ref 不存在 → 404
   {"error": "route_experts not offloaded",
    "hint": "feature was off when stored, or field absent in original response"}
3. status='uploading' → 202 Retry-After: 30
4. status='ready' → StreamingResponse(blob.get_streaming(ref.blob_key),
                                      media_type='application/json')
5. status='consumed' → 410 Gone（本期默认不标记，不会触发）
```

---

## 十、行为矩阵

| 场景 | enabled=false（默认） | enabled=true |
|------|----------------------|--------------|
| Pipeline `_store_trajectory` | 原样，调裸 RequestRepository | 调 OffloadingRepository，透明抽 routed_experts |
| routed_experts 去向 | 存入 `request_details_active` JSON | 抽出 → 异步上传 CSB/Local → PG 存 marker |
| `GET .../records/{id}` 返回 | 完整 routed_experts 原值 | marker `{"_offloaded": true, "backend": ..., "location": ...}` |
| `GET .../records/{id}/route_experts` | 404（无引用行） | 200 流式返回 / 202 上传中 |
| client 直访存储 | N/A（routed_experts 在 PG） | CSB：三步认证 GET；Local：open(path) |
| 推理响应延迟 | 不变 | 不变（上传 fire-and-forget） |
| PG 存储 | 含 routed_experts 大字段 | 仅 marker（几百字节） |
| 现有测试 | 全绿 | 全绿（Pipeline 代码未动） |

---

## 十一、失败模式与处理

| 失败点 | 影响 | 处理 |
|--------|------|------|
| 上传 task 异常 | ref 留 `uploading`，routed_experts 暂不可回拉 | 日志告警；`expires_at` 到期后未来清理任务回收；client 直访得 404 退避重试 |
| 上传成功但 `mark_ready` 失败 | ref 留 `uploading`，但 blob 已在 | 未来清理任务扫描 `uploading` 且超时的，`head` blob 后修复状态 |
| `ref_repo.insert_ref` 失败 | 无引用行，但 routed_experts 未被 strip | **关键**：insert 失败 → 不 strip → 退化原行为，PG 存大字段 |
| `inner.insert` 失败 | ref 行在，blob 在上传中，轨迹未存 | client 回拉得 404（轨迹查不到）；ref 孤儿 TTL 回收 |
| 本地盘满 | `put` 抛异常 | 同"上传 task 异常" |
| CSB 不可达 | `put` 超时/失败 | 同"上传 task 异常" |

---

## 十二、文件清单

### 12.1 新增文件

| 文件 | 职责 |
|------|------|
| `traj_proxy/store/blob_storage.py` | `BlobStorage` ABC + `CSBBlobStorage` + `LocalDiskBlobStorage` + `create_blob_storage` 工厂 |
| `traj_proxy/store/r3_ref_repository.py` | `R3RefRepository`：引用表 CRUD |
| `traj_proxy/store/offloading_repository.py` | `OffloadingRepository`：Decorator，抽 routed_experts + 插引用 + 异步上传 + delegate |
| `tests/store/test_offloading_repository.py` | 单测：strip / insert / delegate / failure 逻辑 |

### 12.2 修改文件（最小改动）

| 文件 | 改动 | 性质 |
|------|------|------|
| `traj_proxy/workers/worker.py` | 组装处加 `if config.enabled: repo = OffloadingRepository(...)` | 单点开关 |
| `traj_proxy/serve/routes.py` | 加 `GET /trajectories/{session_id}/records/{request_id}/route_experts` | 纯新增路由 |
| `traj_proxy/proxy_core/provider.py` | 加 `get_route_experts()` 方法 | 纯新增方法 |
| `traj_proxy/utils/config.py` + `configs/config.yaml` | 加 `route_experts_offload` 配置段 | 纯新增配置 |
| `dockers/compose/scripts/entrypoint.sh` | 追加 `r3_blob_refs` 建表 DDL | 幂等追加 |

### 12.3 不改动

`pipeline/base.py`、`direct_pipeline.py`、`token_pipeline.py`、`processor.py`、`processor_manager.py`、`context.py`、`request_repository.py`、`infer_client.py`、所有 converter / builder。

`offloading_repository.py` 是唯一知道"routed_experts 在 `choices[0]` 哪个字段"的地方，全部 R3 业务逻辑收敛在此，不外泄。

---

## 十三、模块依赖关系

```
traj_proxy/store/
├── blob_storage.py          ← 新（独立，依赖 requests/boto3 已在 requirements）
├── r3_ref_repository.py     ← 新（依赖 database_manager 的 pool）
├── offloading_repository.py ← 新（依赖 RequestRepository 协议 + blob_storage + r3_ref_repository）
├── request_repository.py    ← 不动
├── database_manager.py      ← 不动
└── models.py                ← 不动（r3_blob_refs 行通过 R3RefRepository 返回 Dict，无需 dataclass）

traj_proxy/workers/worker.py ← 组装开关
traj_proxy/serve/routes.py   ← 新路由
traj_proxy/proxy_core/provider.py ← 新方法
```

---

## 十四、未来扩展（本期不做，已预留）

1. **清理任务**：加 `traj_proxy/store/r3_cleanup.py`，`asyncio.create_task` 循环 + `FOR UPDATE SKIP LOCKED`，删 `status='consumed'` 或 `expires_at < now` 的。schema 已预留字段。
2. **S3/MinIO 后端**：`BlobStorage` 加 `S3BlobStorage` 实现，工厂加分支。
3. **consume-on-read**：fallback 端点调 `mark_consumed`，支持"使用后清理"语义。
4. **上传重试**：后台扫描 `status='uploading'` 且超时的，重试上传。
5. **预签名 URL**：若 CSB 支持，响应 marker 直接带预签名 URL，client 无需自带凭证。
