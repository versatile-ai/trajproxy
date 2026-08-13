#!/bin/bash
# TrajProxy 统一入口脚本
# 1. 初始化数据库（创建数据库、表、索引）
# 2. 启动应用

set -e

echo "=== TrajProxy 容器启动 ==="

# ============================================
# 第一阶段：数据库初始化（内嵌 Python 代码）
# ============================================

if [ -n "${DATABASE_URL}" ]; then
    echo "--- 数据库初始化 ---"

    python3 - <<'PYTHON_SCRIPT'
import os
import sys
import re
import psycopg

def init_database():
    """初始化数据库：创建数据库、表、索引"""
    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("错误: 未设置 DATABASE_URL 环境变量")
        sys.exit(1)

    # 解析数据库连接信息
    from urllib.parse import urlparse
    parsed = urlparse(db_url)
    db_name = parsed.path.lstrip("/")
    host = parsed.hostname
    port = parsed.port or 5432
    user = parsed.username
    password = parsed.password

    # 验证标识符
    identifier_pattern = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
    if not identifier_pattern.match(db_name):
        print(f"错误: 无效的数据库名称: {db_name}")
        sys.exit(1)
    if not identifier_pattern.match(user):
        print(f"错误: 无效的用户名称: {user}")
        sys.exit(1)

    default_url = f"postgresql://{user}:{password}@{host}:{port}/postgres"

    # 1. 检查并创建数据库
    print(f"检查数据库 '{db_name}'...")
    try:
        with psycopg.connect(default_url, autocommit=True) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (db_name,))
                if not cur.fetchone():
                    print(f"数据库 '{db_name}' 不存在，正在创建...")
                    cur.execute(
                        "CREATE DATABASE {} OWNER {}".format(
                            psycopg.sql.Identifier(db_name).as_string(conn),
                            psycopg.sql.Identifier(user).as_string(conn),
                        )
                    )
                    print(f"数据库 '{db_name}' 创建成功")
                else:
                    print(f"数据库 '{db_name}' 已存在，跳过")
    except Exception as e:
        print(f"错误: 创建数据库失败: {e}")
        sys.exit(1)

    # 2. 创建表和索引
    print("创建表和索引...")
    try:
        with psycopg.connect(db_url, autocommit=True) as conn:
            # request_metadata 表（元数据，长期保留）
            print("  创建 request_metadata 表...")
            conn.execute("""
                CREATE TABLE IF NOT EXISTS public.request_metadata (
                    id BIGSERIAL PRIMARY KEY,
                    unique_id TEXT NOT NULL UNIQUE,
                    request_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    run_id TEXT,
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
                )
            """)
            print("  request_metadata 表创建完成")

            # 兼容性：为 request_metadata 添加 run_id 列
            print("  检查 request_metadata 表列兼容性...")
            has_run_id = conn.execute("""
                SELECT EXISTS(SELECT 1 FROM information_schema.columns
                              WHERE table_schema='public'
                              AND table_name='request_metadata'
                              AND column_name='run_id')
            """).fetchone()[0]

            if not has_run_id:
                conn.execute("ALTER TABLE public.request_metadata ADD COLUMN run_id TEXT")
                print("  run_id 列添加完成")

            # request_metadata 索引
            print("  创建 request_metadata 索引...")
            conn.execute("CREATE INDEX IF NOT EXISTS request_metadata_session_id_idx ON public.request_metadata (session_id)")
            conn.execute("CREATE INDEX IF NOT EXISTS request_metadata_run_id_idx ON public.request_metadata (run_id)")
            conn.execute("CREATE INDEX IF NOT EXISTS request_metadata_start_time_idx ON public.request_metadata (start_time DESC)")
            conn.execute("CREATE INDEX IF NOT EXISTS request_metadata_archive_location_idx ON public.request_metadata (archive_location) WHERE archive_location IS NOT NULL")

            # request_details_active 表（详情大字段，按月分区，只存近期）
            print("  创建 request_details_active 分区表...")
            conn.execute("""
                CREATE TABLE IF NOT EXISTS public.request_details_active (
                    id BIGSERIAL,
                    unique_id TEXT NOT NULL
                        REFERENCES public.request_metadata(unique_id) ON DELETE CASCADE,
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
                ) PARTITION BY RANGE (created_at)
            """)
            print("  request_details_active 分区表创建完成")

            # 创建月分区（处理默认分区数据冲突）
            import datetime as _dt

            def _create_month_partition(conn, target_date):
                """创建指定月份的分区，处理默认分区数据冲突"""
                _ms = target_date.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
                if target_date.month == 12:
                    _me = _ms.replace(year=target_date.year + 1, month=1)
                else:
                    _me = _ms.replace(month=target_date.month + 1)
                _pn = f"request_details_active_{target_date.strftime('%Y_%m')}"

                # 分区已存在则跳过
                if conn.execute(f"""
                    SELECT 1 FROM pg_class
                    WHERE relname = '{_pn}' AND relnamespace = 'public'::regnamespace
                """).fetchone():
                    return

                try:
                    conn.execute(f"""
                        CREATE TABLE public.{_pn}
                            PARTITION OF public.request_details_active
                            FOR VALUES FROM ('{_ms.isoformat()}') TO ('{_me.isoformat()}')
                    """)
                    print(f"  创建分区: {_pn}")
                except Exception as _e:
                    _err = str(_e)
                    if "default partition" not in _err or "would be violated" not in _err:
                        raise

                    # 升级场景：默认分区包含冲突数据，迁移到新分区
                    print(f"  检测到默认分区数据冲突，迁移 {_pn} 数据...")
                    conn.execute("""
                        ALTER TABLE public.request_details_active
                        DETACH PARTITION public.request_details_active_default
                    """)
                    conn.execute(f"""
                        CREATE TABLE public.{_pn}
                            PARTITION OF public.request_details_active
                            FOR VALUES FROM ('{_ms.isoformat()}') TO ('{_me.isoformat()}')
                    """)
                    conn.execute(f"""
                        INSERT INTO public.{_pn}
                            SELECT * FROM public.request_details_active_default
                            WHERE created_at >= '{_ms.isoformat()}'
                              AND created_at < '{_me.isoformat()}'
                    """)
                    conn.execute(f"""
                        DELETE FROM public.request_details_active_default
                        WHERE created_at >= '{_ms.isoformat()}'
                          AND created_at < '{_me.isoformat()}'
                    """)
                    conn.execute("""
                        ALTER TABLE public.request_details_active
                        ATTACH PARTITION public.request_details_active_default DEFAULT
                    """)
                    print(f"  数据迁移完成: {_pn}")

            # 创建当月 + 下月分区（下月分区预防跨月运行时数据落入默认分区）
            _now = _dt.datetime.now()
            _create_month_partition(conn, _now)
            if _now.month == 12:
                _next = _now.replace(year=_now.year + 1, month=1)
            else:
                _next = _now.replace(month=_now.month + 1)
            _create_month_partition(conn, _next)

            # 默认分区（兜底）
            print("  创建默认分区...")
            conn.execute("""
                CREATE TABLE IF NOT EXISTS public.request_details_active_default
                    PARTITION OF public.request_details_active DEFAULT
            """)
            print("  默认分区创建完成")

            # request_details_active 索引
            print("  创建 request_details_active 索引...")
            conn.execute("CREATE INDEX IF NOT EXISTS request_details_active_unique_id_idx ON public.request_details_active (unique_id)")

            # model_registry 表
            print("  创建 model_registry 表...")
            conn.execute("""
                CREATE TABLE IF NOT EXISTS public.model_registry (
                    id SERIAL PRIMARY KEY,
                    run_id TEXT,
                    model_name TEXT NOT NULL,
                    url TEXT NOT NULL,
                    api_key TEXT NOT NULL,
                    tokenizer_path TEXT,
                    token_in_token_out BOOLEAN DEFAULT FALSE,
                    tool_parser TEXT NOT NULL DEFAULT '',
                    reasoning_parser TEXT NOT NULL DEFAULT '',
                    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
                    CONSTRAINT unique_run_model UNIQUE (run_id, model_name)
                )
            """)
            print("  model_registry 表创建完成")

            # model_registry 索引
            print("  创建 model_registry 索引...")
            conn.execute("CREATE INDEX IF NOT EXISTS model_registry_run_id_idx ON public.model_registry (run_id)")
            conn.execute("CREATE INDEX IF NOT EXISTS model_registry_model_name_idx ON public.model_registry (model_name)")
            conn.execute("CREATE INDEX IF NOT EXISTS model_registry_updated_at_idx ON public.model_registry (updated_at DESC)")

            # r3_blob_refs 表（route_experts 大字段卸载引用）
            # session_id 列用于多租户授权：fallback 端点必须按 (session_id, request_id)
            # 复合查询，防止任意客户端凭他人 request_id 读取他人 route_experts
            print("  创建 r3_blob_refs 表...")
            conn.execute("""
                CREATE TABLE IF NOT EXISTS public.r3_blob_refs (
                    request_id   TEXT PRIMARY KEY,
                    session_id   TEXT NOT NULL,
                    blob_key     TEXT NOT NULL,
                    backend      TEXT NOT NULL,
                    status       TEXT NOT NULL DEFAULT 'uploading',
                    size_bytes   BIGINT,
                    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
                    ready_at     TIMESTAMPTZ,
                    consumed_at  TIMESTAMPTZ,
                    expires_at   TIMESTAMPTZ NOT NULL
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_r3_status_ready
                    ON public.r3_blob_refs (expires_at)
                    WHERE status IN ('uploading', 'ready')
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_r3_status_consumed
                    ON public.r3_blob_refs (consumed_at)
                    WHERE status = 'consumed'
            """)
            # 多租户授权复合索引：fallback 端点按 (session_id, request_id) 查询
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_r3_session_request
                    ON public.r3_blob_refs (session_id, request_id)
            """)
            print("  r3_blob_refs 表和索引创建完成")

            # r3_blob_refs 兼容性: 旧版本创建的表可能缺 session_id 列, 需补列
            print("  检查 r3_blob_refs 表列兼容性...")
            has_session_id = conn.execute("""
                SELECT EXISTS(
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public'
                      AND table_name = 'r3_blob_refs'
                      AND column_name = 'session_id'
                )
            """).fetchone()[0]
            if not has_session_id:
                print("  补充 r3_blob_refs.session_id 列 (旧版本升级)...")
                # 先加列 (默认 NULL, 避免旧行 NOT NULL 报错)
                conn.execute("ALTER TABLE public.r3_blob_refs ADD COLUMN session_id TEXT")
                # 回填已有行的 session_id: 从 request_metadata JOIN 取 (request_id 关联)
                # 若 JOIN 不到, 用 'unknown' 占位
                conn.execute("""
                    UPDATE public.r3_blob_refs r
                    SET session_id = COALESCE(
                        (SELECT m.session_id FROM public.request_metadata m
                         WHERE m.request_id = r.request_id),
                        'unknown'
                    )
                    WHERE r.session_id IS NULL
                """)
                # 回填后加 NOT NULL 约束
                conn.execute("ALTER TABLE public.r3_blob_refs ALTER COLUMN session_id SET NOT NULL")
                # 补复合索引 (若不存在)
                conn.execute("""
                    CREATE INDEX IF NOT EXISTS idx_r3_session_request
                        ON public.r3_blob_refs (session_id, request_id)
                """)
                print("  r3_blob_refs.session_id 列补充完成")
            else:
                print("  r3_blob_refs.session_id 列已存在, 跳过")

            # 兼容性：为 model_registry 添加新列
            print("  检查 model_registry 表列兼容性...")
            conn.execute("""
                DO $$
                BEGIN
                    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                                   WHERE table_schema='public' AND table_name='model_registry' AND column_name='tool_parser') THEN
                        ALTER TABLE public.model_registry ADD COLUMN tool_parser TEXT NOT NULL DEFAULT '';
                    END IF;
                    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                                   WHERE table_schema='public' AND table_name='model_registry' AND column_name='reasoning_parser') THEN
                        ALTER TABLE public.model_registry ADD COLUMN reasoning_parser TEXT NOT NULL DEFAULT '';
                    END IF;
                END $$;
            """)

            # 修改 tokenizer_path 为可空（直接转发模式不需要）
            conn.execute("""
                DO $$
                BEGIN
                    -- 检查 tokenizer_path 是否有 NOT NULL 约束
                    IF EXISTS (
                        SELECT 1 FROM information_schema.columns
                        WHERE table_schema='public'
                        AND table_name='model_registry'
                        AND column_name='tokenizer_path'
                        AND is_nullable='NO'
                    ) THEN
                        ALTER TABLE public.model_registry ALTER COLUMN tokenizer_path DROP NOT NULL;
                    END IF;
                END $$;
            """)

            print("表和索引创建完成")
    except Exception as e:
        print(f"错误: 创建表失败: {e}")
        sys.exit(1)

    print("--- 数据库初始化完成 ---")

if __name__ == "__main__":
    init_database()
PYTHON_SCRIPT

    if [ $? -ne 0 ]; then
        echo "错误: 数据库初始化失败，退出"
        exit 1
    fi
else
    echo "警告: 未设置 DATABASE_URL，跳过数据库初始化"
fi

# ============================================
# 第二阶段：启动应用
# ============================================

echo "=== 启动 TrajProxy 服务 ==="
exec python -m traj_proxy.app
