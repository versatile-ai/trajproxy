"""
OffloadingRepository - route_experts 大字段卸载 Decorator

功能边界:
    包裹 RequestRepository，透明地将 route_experts 字段卸载到外部 blob 存储
    （CSB / Local）。本类是唯一知道 route_experts 在 ProcessContext 中位置
    （choices[0].route_experts，位于 token_response 或 raw_response）的组件，
    全部 R3 业务逻辑收敛于此，不外泄到 Pipeline / Processor。

    关闭时 Worker 直接使用裸 RequestRepository，本类不参与（零影响）。

对外接口:
    - insert(context, tokenizer_path, run_id): 抽取 route_experts → 插引用行
      → fire-and-forget 上传 → 原位替换为 marker → delegate 给 inner
    - 其他 RequestRepository 公共方法: 通过 __getattr__ 透明委托给 inner

依赖关系:
    - traj_proxy.store.blob_storage.BlobStorage（put / open_stream / delete / exists）
    - traj_proxy.store.r3_ref_repository.R3RefRepository（insert_ref / mark_ready）
    - traj_proxy.store.request_repository.RequestRepository（被包裹的 inner）
    - traj_proxy.proxy_core.context.ProcessContext（route_experts 数据来源）
    - traj_proxy.utils.logger（统一日志，禁止 print）
    设计文档: docs/design/features/route-experts-offload.md
"""

# allow: SIZE_OK — awk 统计 299 行（含项目强制中文 docstring）。
# 单一职责: OffloadingRepository Decorator，所有方法围绕 insert() 卸载流程内聚，
# 拆分将破坏 cohesion。docstring 行数由全局规则（功能边界/对外接口/依赖关系）要求。

import asyncio
import json
from datetime import datetime, timedelta, timezone
from typing import Any, Optional, Tuple, TYPE_CHECKING

from traj_proxy.store.blob_storage import BlobStorage
from traj_proxy.store.r3_ref_repository import R3RefRepository
from traj_proxy.store.request_repository import RequestRepository
from traj_proxy.utils.logger import get_logger

if TYPE_CHECKING:
    from traj_proxy.proxy_core.context import ProcessContext

logger = get_logger(__name__)

# None 值的 blob_key 路径占位符，避免路径中出现 "None" 字符串
_UNKNOWN_SEGMENT = "unknown"

# P1-2: 单个 route_experts 序列化后字节上限，超过则退化原行为（PG 存大字段）。
# 设计文档峰值 500GB/小时为聚合流量，单请求体量无明确上限；
# 50MB 阈值兼顾内存压力与"避免一次性把超大对象载入内存"的防御。
_ROUTE_EXPERTS_MAX_BYTES = 50 * 1024 * 1024


class OffloadingRepository:
    """包裹 RequestRepository 的 Decorator，透明卸载 route_experts

    实现设计文档 docs/design/features/route-experts-offload.md 四.3 的伪代码。
    insert 顺序保证失败安全性: ref insert 失败 → 不 strip → 退化原行为
    （PG 存大字段，无数据丢失）。

    其他公共方法（get_record_detail / get_by_session 等）通过 __getattr__
    透明委托给 inner Repository，对调用方完全透明。
    """

    def __init__(
        self,
        inner: RequestRepository,
        blob: BlobStorage,
        ref_repo: R3RefRepository,
        backend: str,
        marker_config: dict,
        ttl_hours: int,
        blob_key_prefix: str = "route_experts",
    ) -> None:
        """初始化 OffloadingRepository。

        Args:
            inner: 被包裹的 RequestRepository 实例，承担实际的 PG 读写。
            blob: BlobStorage 实例（CSB / Local），用于上传 route_experts 数据。
            ref_repo: R3RefRepository 实例，用于管理 r3_blob_refs 引用表。
            backend: 存储后端标识，"csb" 或 "local"，写入 marker.backend。
            marker_config: 构造响应 marker 所需的 access 侧参数。
                CSB: {"endpoint": ..., "bucket": ...}
                Local: {"access_path": ...}
            ttl_hours: 引用行过期时间（小时），expires_at = now() + ttl。
            blob_key_prefix: blob key 前缀，默认 "route_experts"。
        """
        # 先初始化 _inner，避免 __getattr__ 在构造期间触发无限递归
        self._inner = inner
        self._blob = blob
        self._ref_repo = ref_repo
        self._backend = backend
        self._marker_config = marker_config
        self._ttl_hours = ttl_hours
        self._blob_key_prefix = blob_key_prefix
        # P0-#1: 强引用后台上传 task，避免被 GC 静默丢弃（Python 官方文档警告）
        self._bg_tasks: set[asyncio.Task] = set()
        logger.info(
            f"OffloadingRepository 初始化: backend={backend}, "
            f"ttl_hours={ttl_hours}, prefix={blob_key_prefix}"
        )

    async def insert(
        self,
        context: "ProcessContext",
        tokenizer_path: Optional[str] = None,
        run_id: Optional[str] = None,
    ) -> None:
        """插入轨迹记录，透明卸载 route_experts 到外部存储。

        流程（设计文档 四.3）:
            1. 抽取 route_experts（不改 context）; 未找到则直接 delegate
            2. 生成 blob_key
            3. 插入 r3_blob_refs 引用行（失败则不 strip，退化原行为）
            4. fire-and-forget 异步上传 blob + mark_ready
            5. 原位替换 route_experts 为直访 marker
            6. delegate 给 inner.insert；失败则回滚 context（P0-1 修复）

        失败安全性（设计文档 十一 + P0-1 修复）:
            - ref insert 失败 → 不 strip → 退化原行为（PG 存大字段）
            - 序列化后超 _ROUTE_EXPERTS_MAX_BYTES → 不 strip → 退化原行为（P1-2）
            - 上传失败 → ref 留 uploading，TTL 回收
            - inner.insert 失败 → 回滚 context 恢复原始 route_experts，
              client 收到原始数据而非 marker，避免"拿 marker 找不到根"的数据丢失（P0-1）

        Args:
            context: 处理上下文，route_experts 位于
                     context.token_response["choices"][0]["routed_experts"]（TITO）
                     或 context.raw_response["choices"][0]["routed_experts"]（Direct）。
            tokenizer_path: Tokenizer 路径（透传给 inner）。
            run_id: 运行 ID（透传给 inner，同时用于 blob_key 生成）。
        """
        # 1. 抽取 route_experts（不改 context）
        extracted = self._extract(context)
        if extracted is None:
            # 未找到 route_experts，直接 delegate，无卸载（E6 场景）
            return await self._inner.insert(context, tokenizer_path, run_id)
        re_data, source_field = extracted

        # 2. 生成 blob_key
        blob_key = self._make_blob_key(run_id, context.session_id, context.request_id)

        # 3. 插入引用行（失败则不 strip，退化原行为）
        # 预序列化用于 size_bytes 计算；同一份 bytes 传入后台任务避免二次序列化
        # 序列化与 ref insert 同置于 try 块：任一失败均退化原行为
        try:
            # P2-#11: 大字段 json.dumps 同步阻塞事件循环，卸载到线程池
            serialized = await asyncio.to_thread(
                lambda: json.dumps(re_data, ensure_ascii=False).encode("utf-8")
            )
            size_bytes = len(serialized)
            # P1-2: 超阈值退化原行为，避免一次性把超大对象载入内存
            if size_bytes > _ROUTE_EXPERTS_MAX_BYTES:
                logger.warning(
                    f"route_experts 序列化后 {size_bytes} bytes 超阈值 "
                    f"{_ROUTE_EXPERTS_MAX_BYTES}，退化原行为: "
                    f"request_id={context.request_id}"
                )
                return await self._inner.insert(context, tokenizer_path, run_id)
            expires_at = datetime.now(timezone.utc) + timedelta(hours=self._ttl_hours)
            # session_id NOT NULL, 用占位符避免 context.session_id 为 None 时 DB 报错
            session_id_for_ref = context.session_id or _UNKNOWN_SEGMENT
            await self._ref_repo.insert_ref(
                request_id=context.request_id,
                session_id=session_id_for_ref,
                blob_key=blob_key,
                backend=self._backend,
                size_bytes=size_bytes,
                expires_at=expires_at,
            )
        except Exception:
            # 设计文档 十一: ref insert 失败 → 不 strip → 退化原行为
            # 此处捕获 Exception 而非具体类型，因为退化逻辑必须覆盖任何失败
            # （DatabaseError / 连接池耗尽 / 序列化异常等），保证不丢数据
            logger.warning(
                f"r3 ref insert 失败，跳过卸载，退化原行为: "
                f"request_id={context.request_id}, blob_key={blob_key}",
                exc_info=True,
            )
            # route_experts 未被 strip，context 保持原样，PG 存大字段
            return await self._inner.insert(context, tokenizer_path, run_id)

        # 4. fire-and-forget 异步上传（不阻塞响应）
        # P0-#1: 强引用 task 防止 GC 丢弃；完成时从 set 中移除
        task = asyncio.create_task(
            self._upload_and_mark_ready(blob_key, serialized, context.request_id)
        )
        self._bg_tasks.add(task)
        task.add_done_callback(self._bg_tasks.discard)

        # 5. 原位替换 route_experts 为直访 marker
        self._replace_with_marker(context, source_field, blob_key)

        # 6. delegate 给 inner（PG 存的是轻量 marker）
        # P0-1 修复：inner.insert 失败时回滚 context，恢复原始 route_experts。
        # 否则 client 收到 marker 但轨迹未存，拿 marker 既查不到轨迹也回拉不到 blob，
        # 原始 route_experts 永久丢失。回滚后 client 收到原始数据，无需回拉。
        # 注意：后台 task 已起（步骤 4），ref 行已入库；回滚只还原 context，
        # ref 孤儿由 TTL 回收（未来清理任务）。task 上传仍会完成，不影响数据安全。
        try:
            return await self._inner.insert(context, tokenizer_path, run_id)
        except Exception:
            logger.warning(
                f"inner.insert 失败，回滚 context 恢复原始 route_experts: "
                f"request_id={context.request_id}, blob_key={blob_key}",
                exc_info=True,
            )
            self._restore_route_experts(context, source_field, re_data)
            raise

    async def _upload_and_mark_ready(
        self,
        blob_key: str,
        data: bytes,
        request_id: str,
    ) -> None:
        """后台任务: 上传 blob 并标记引用行为 ready。

        fire-and-forget 调用，任何异常都被捕获并记录:
            - 上传失败 → ref 留 uploading，未来清理任务按 expires_at 回收
            - mark_ready 失败 → ref 留 uploading，blob 已在，未来清理任务修复

        Args:
            blob_key: blob 存储键。
            data: 已序列化的 route_experts 字节流。
            request_id: 请求 ID，用于 mark_ready。
        """
        try:
            # P3-#13: insert 唯一调用点已传 bytes，直接用；防御性 isinstance 已删除（死代码）
            await self._blob.put(blob_key, data)
            await self._ref_repo.mark_ready(request_id)
            logger.info(
                f"route_experts uploaded: key={blob_key}, "
                f"size={len(data)}"
            )
        except Exception as e:
            # 设计文档 十一: 上传 task 异常 → ref 留 uploading，TTL 回收
            logger.error(
                f"route_experts upload failed: key={blob_key}, "
                f"request_id={request_id}, error={e}",
                exc_info=True,
            )
            # ref 保持 'uploading' 状态，未来清理任务按 expires_at 回收

    def _extract(
        self,
        context: "ProcessContext",
    ) -> Optional[Tuple[Any, str]]:
        """从 ProcessContext 中查找 route_experts 字段。

        查找顺序（设计文档 四.4）:
            1. token_response["choices"][0]["routed_experts"]（TITO Pipeline）
            2. raw_response["choices"][0]["routed_experts"]（Direct Pipeline）

        仅读取，不修改 context。

        P2-1 防护：若 routed_experts 已是 marker（含 `_offloaded: True`），
        跳过该字段。防止重试或二次 insert 场景下把 marker 当作原始数据上传，
        导致 blob 里存的是 marker 而非真实 route_experts（静默数据损坏）。

        Args:
            context: 处理上下文。

        Returns:
            (route_experts_data, source_field_name) 或 None。
            source_field 为 "token_response" 或 "raw_response"。
            返回 Optional[Tuple[...]] 保证 data 与 source_field 同现同缺，
            使调用方无需对 source_field 单独做空值判断。
        """
        for attr in ("token_response", "raw_response"):
            data = getattr(context, attr, None)
            if not isinstance(data, dict):
                continue
            choices = data.get("choices")
            if not isinstance(choices, list) or not choices:
                continue
            first_choice = choices[0]
            if not isinstance(first_choice, dict):
                continue
            if "routed_experts" not in first_choice:
                continue
            re_value = first_choice["routed_experts"]
            # P2-1: 已是 marker 则跳过，避免把 marker 当原始数据二次卸载
            if (
                isinstance(re_value, dict)
                and re_value.get("_offloaded") is True
            ):
                continue
            return re_value, attr
        return None

    def _replace_with_marker(
        self,
        context: "ProcessContext",
        source_field: str,
        blob_key: str,
    ) -> None:
        """原位替换 context 中 route_experts 为直访 marker。

        修改 context.{source_field}["choices"][0]["routed_experts"] 为 marker dict。
        调用时 _extract 已确认 source_field 对应的响应存在且结构合法。

        Args:
            context: 处理上下文（将被原位修改）。
            source_field: "token_response" 或 "raw_response"。
            blob_key: blob 存储键，写入 marker.location。
        """
        data = getattr(context, source_field)
        data["choices"][0]["routed_experts"] = self._build_marker(blob_key)

    def _restore_route_experts(
        self,
        context: "ProcessContext",
        source_field: str,
        original_data: Any,
    ) -> None:
        """inner.insert 失败时回滚 context，恢复原始 route_experts（P0-1）。

        _replace_with_marker 已把 routed_experts 改为 marker；若 inner.insert
        随后失败，必须还原原始数据，否则 client 收到 marker 但轨迹未存，
        原始 route_experts 永久丢失。本方法把 marker 原位替换回 original_data。

        Args:
            context: 处理上下文（已被 marker 污染，将被还原）。
            source_field: "token_response" 或 "raw_response"。
            original_data: _extract 返回的原始 route_experts 引用。
        """
        data = getattr(context, source_field)
        data["choices"][0]["routed_experts"] = original_data

    def _build_marker(self, blob_key: str) -> dict:
        """构造直访 marker（设计文档 七）。

        CSB: {"_offloaded": True, "backend": "csb",
              "location": {"endpoint": ..., "bucket": ..., "key": blob_key}}
        Local: {"_offloaded": True, "backend": "local",
                "location": {"path": access_path + "/" + blob_key}}

        不放 status 字段（设计文档 七.3: fire-and-forget 下 status 会误导
        client 以为需要轮询；小时级回拉时上传早完成，404 就退避重试）。

        Args:
            blob_key: blob 存储键。

        Returns:
            marker 字典，将替换原始 route_experts 存入 PG JSON。
        """
        if self._backend == "csb":
            return {
                "_offloaded": True,
                "backend": "csb",
                "location": {
                    "endpoint": self._marker_config.get("endpoint", ""),
                    "bucket": self._marker_config.get("bucket", ""),
                    "key": blob_key,
                },
            }
        # local 后端
        access_path = self._marker_config.get("access_path", "")
        return {
            "_offloaded": True,
            "backend": "local",
            "location": {
                "path": f"{access_path}/{blob_key}",
            },
        }

    def _make_blob_key(
        self,
        run_id: Optional[str],
        session_id: Optional[str],
        request_id: str,
    ) -> str:
        """生成 blob 存储键（设计文档 八.3）。

        格式: {prefix}/{run_id}/{session_id}/{request_id}.json
        None 的 run_id/session_id 用 "unknown" 占位，避免路径出现 "None"。
        按 run_id / session_id 分层，便于按 run 或 session 浏览/批量操作。

        Args:
            run_id: 运行 ID（可能为 None）。
            session_id: 会话 ID（可能为 None）。
            request_id: 请求 ID（必填）。

        Returns:
            blob 存储键字符串。
        """
        run_seg = self._sanitize_path_segment(run_id or _UNKNOWN_SEGMENT)
        session_seg = self._sanitize_path_segment(session_id or _UNKNOWN_SEGMENT)
        request_seg = self._sanitize_path_segment(request_id)
        return f"{self._blob_key_prefix}/{run_seg}/{session_seg}/{request_seg}.json"

    @staticmethod
    def _sanitize_path_segment(segment: str) -> str:
        """清理路径段，防止路径穿越。

        将 /、\\、.. 替换为 _，确保 segment 不会逃逸出 blob_key_prefix 目录。
        防御 client 传入恶意 run_id/session_id 导致 LocalDiskBlobStorage 写越界。
        """
        sanitized = segment.replace("/", "_").replace("\\", "_").replace("..", "_")
        return sanitized or _UNKNOWN_SEGMENT

    def __getattr__(self, name: str) -> Any:
        """透明委托: 未在本类定义的属性/方法委托给 inner RequestRepository。

        被 RequestRepository 公共方法（get_record_detail / get_by_session /
        get_metadata_by_session / get_statistics / list_sessions /
        get_all_by_session / get_prefix_candidates 等）调用时，自动转发给
        self._inner，保证 Decorator 对调用方完全透明。

        __getattr__ 仅在常规属性查找失败时触发，不影响本类已定义的方法
        （insert / _extract / _build_marker 等）。

        Args:
            name: 属性名。

        Returns:
            inner Repository 上对应的属性（方法或值）。

        Raises:
            AttributeError: _inner 尚未初始化时抛出（避免无限递归）。
        """
        # 避免构造期间或 unpickling 时 _inner 尚未设置触发无限递归
        try:
            inner = object.__getattribute__(self, "_inner")
        except AttributeError:
            raise AttributeError(name)
        return getattr(inner, name)

    async def aclose(self) -> None:
        """取消并等待所有未完成的后台上传任务，供 Worker shutdown 调用。

        保证 shutdown 时不会留下被取消的孤儿 task 警告。
        幂等：多次调用安全；无任务时立即返回。
        """
        if not self._bg_tasks:
            return
        for task in list(self._bg_tasks):
            if not task.done():
                task.cancel()
        try:
            await asyncio.gather(*self._bg_tasks, return_exceptions=True)
        finally:
            self._bg_tasks.clear()
