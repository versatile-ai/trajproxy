#!/bin/bash
# Archive 层测试工具函数
# 适配独立归档进程 traj_archiver + 本地/ S3 双模式存储

# 导入配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# 导入公共工具函数
source "${SCRIPT_DIR}/../../utils.sh"

# ========================================
# 数据库操作函数
# ========================================

# 执行 SQL 查询（在数据库容器内运行）
db_query() {
    local sql="$1"
    echo "$sql" | docker exec -i "${DB_CONTAINER_NAME}" \
        env PGPASSWORD="${ARCHIVE_DB_PASSWORD}" psql \
        -h "${ARCHIVE_DB_HOST}" -p "${ARCHIVE_DB_PORT}" \
        -U "${ARCHIVE_DB_USER}" -d "${ARCHIVE_DB_NAME}" \
        -t -A
}

# 执行 SQL 命令（无输出）
db_execute() {
    local sql="$1"
    echo "$sql" | docker exec -i "${DB_CONTAINER_NAME}" \
        env PGPASSWORD="${ARCHIVE_DB_PASSWORD}" psql \
        -h "${ARCHIVE_DB_HOST}" -p "${ARCHIVE_DB_PORT}" \
        -U "${ARCHIVE_DB_USER}" -d "${ARCHIVE_DB_NAME}" \
        -q
}

# ========================================
# 测试数据生成函数
# ========================================

# 创建指定月份的分区（已存在时检查边界，不对则重建）
create_partition() {
    local year_month="$1"  # 格式: YYYY_MM
    local year="${year_month:0:4}"
    local month="${year_month:5:2}"

    local next_month=$((10#$month + 1))
    local next_year=$year
    if [ $next_month -gt 12 ]; then
        next_month=1
        next_year=$((year + 1))
    fi

    local month_start="${year}-${month}-01"
    local next_month_start="${next_year}-$(printf '%02d' $next_month)-01"

    local partition_name="request_details_active_${year_month}"

    # 检查分区是否已存在
    local exists=$(db_query "
        SELECT COUNT(*) FROM pg_class
        WHERE relname = '${partition_name}'
        AND relnamespace = 'public'::regnamespace;
    ")

    if [ "${exists:-0}" -gt 0 ]; then
        # 已存在：检查边界是否正确
        local actual_range=$(db_query "
            SELECT pg_get_expr(relpartbound, oid)
            FROM pg_class
            WHERE relname = '${partition_name}'
            AND relnamespace = 'public'::regnamespace;
        ")
        local expected_lower="('${month_start}'"
        if echo "$actual_range" | grep -q "$expected_lower"; then
            log_info "分区 ${partition_name} 已存在且边界正确"
            return 0
        fi

        # 边界不对，重建
        log_info "分区 ${partition_name} 边界不正确，重建中..."
        db_execute "ALTER TABLE public.request_details_active DETACH PARTITION public.${partition_name};" 2>/dev/null
        db_execute "DROP TABLE IF EXISTS public.${partition_name};"
    fi

    db_execute "
        CREATE TABLE IF NOT EXISTS public.${partition_name}
            PARTITION OF public.request_details_active
            FOR VALUES FROM ('${month_start}') TO ('${next_month_start}');
    "

    log_info "已创建分区: ${partition_name}"
}

# 插入测试数据到指定分区
insert_test_data() {
    local year_month="$1"
    local count="${2:-10}"
    local session_id="${3:-${TEST_SESSION_PREFIX}}"
    local run_id="${4:-test-run-archive}"

    local year="${year_month:0:4}"
    local month="${year_month:5:2}"
    local created_at="${year}-${month}-15 10:00:00"

    for i in $(seq 1 $count); do
        local unique_id="${session_id}_req_${i}"
        local request_id="req_${i}"

        db_execute "
            INSERT INTO request_metadata (
                unique_id, request_id, session_id, run_id, model,
                prompt_tokens, completion_tokens, total_tokens,
                start_time, end_time, created_at
            ) VALUES (
                '${unique_id}', '${request_id}', '${session_id}', '${run_id}', '${TEST_MODEL_NAME}',
                100, 50, 150,
                '${created_at}', '${created_at}', '${created_at}'
            )
            ON CONFLICT (unique_id) DO NOTHING;
        "

        db_execute "
            INSERT INTO request_details_active (
                unique_id, created_at, messages
            ) VALUES (
                '${unique_id}', '${created_at}', '[{\"role\": \"user\", \"content\": \"test message\"}]'::json
            )
            ON CONFLICT DO NOTHING;
        "
    done

    log_info "已插入 ${count} 条测试数据到分区 ${year_month} (run=${run_id})"
}

# 清理测试数据
cleanup_test_data() {
    local session_id="${1:-${TEST_SESSION_PREFIX}}"

    db_execute "DELETE FROM request_details_active WHERE unique_id LIKE '${session_id}%';"
    db_execute "DELETE FROM request_metadata WHERE session_id LIKE '${session_id}%';"

    log_info "已清理测试数据: ${session_id}"
}

# ========================================
# 归档验证函数（双模式：本地 / S3）
# ========================================

# 检查分区是否存在
check_partition_exists() {
    local partition_name="$1"
    local result=$(db_query "
        SELECT COUNT(*) FROM pg_class
        WHERE relname = '${partition_name}'
        AND relnamespace = 'public'::regnamespace;
    ")
    [ "$result" -gt 0 ]
}

# 获取分区记录数
get_partition_record_count() {
    local partition_name="$1"
    local count=$(db_query "SELECT COUNT(*) FROM public.${partition_name};" 2>/dev/null || echo "0")
    echo "${count:-0}"
}

# 获取已归档记录数
get_archived_record_count() {
    local session_id="$1"
    db_query "
        SELECT COUNT(*) FROM request_metadata
        WHERE session_id LIKE '${session_id}%'
        AND archive_location IS NOT NULL;
    "
}

# 获取归档记录的 archive_location
get_archive_location() {
    local session_id="$1"
    db_query "
        SELECT archive_location FROM request_metadata
        WHERE session_id LIKE '${session_id}%'
        AND archive_location IS NOT NULL
        LIMIT 1;
    "
}

# 获取所有运行中的归档容器名称（排除 MinIO 等辅助服务）
_get_archiver_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'archiver' | grep -v 'minio\|minio_init' || true
}

# 判断 archive_location 是否为 S3 URI
_is_s3_uri() {
    local location="$1"
    [[ "$location" == s3://* ]]
}

# 在指定容器中检查本地归档文件
_check_local_file_in_container() {
    local container="$1"
    local archive_location="$2"

    docker exec "${container}" python3 -c "
import os
path = '${archive_location}'
print('exists' if os.path.exists(path) else 'not_found')
" 2>/dev/null | grep -q "exists"
}

# 通过 S3 检查归档文件（用于 archive_location 为 s3:// URI 的情况）
_check_s3_file() {
    local archive_location="$1"

    local result
    result=$(docker exec "${ARCHIVER_CONTAINER_NAME}" python3 -c "
import boto3, os
from urllib.parse import urlparse
uri = '${archive_location}'
p = urlparse(uri)
bucket = p.netloc
key = p.path.lstrip('/')
ep = os.environ.get('AWS_ENDPOINT_URL')
kwargs = {}
if ep:
    kwargs['endpoint_url'] = ep
s3 = boto3.client('s3', **kwargs)
try:
    s3.head_object(Bucket=bucket, Key=key)
    print('exists')
except:
    print('not_found')
" 2>/dev/null)
    [ "$result" = "exists" ]
}

# 通过 S3 检查归档文件（用于 archive_location 为本地路径的情况，尝试用默认 bucket/prefix 查找）
_check_s3_file_by_local_key() {
    local archive_location="$1"

    for container in $(_get_archiver_containers); do
        local result
        result=$(docker exec "${container}" python3 -c "
import boto3, os

# 尝试从环境变量推断 S3 配置
ep = os.environ.get('AWS_ENDPOINT_URL')
bucket = os.environ.get('S3_BUCKET', 'trajproxy-archives')
prefix = os.environ.get('S3_PREFIX', 'archives/')

key = '${archive_location}'
full_key = prefix + key

kwargs = {}
if ep:
    kwargs['endpoint_url'] = ep
try:
    s3 = boto3.client('s3', **kwargs)
    s3.head_object(Bucket=bucket, Key=full_key)
    print('exists')
except:
    print('not_found')
" 2>/dev/null)
        if [ "$result" = "exists" ]; then
            return 0
        fi
    done
    return 1
}

# 检查归档文件是否存在（自动识别本地 / S3，支持多容器和 fallback）
check_archive_file_exists() {
    local archive_location="$1"

    if _is_s3_uri "$archive_location"; then
        # S3 URI：优先 S3 检查，失败则尝试在各容器本地查找
        if _check_s3_file "$archive_location"; then
            return 0
        fi
        # fallback: 尝试从 S3 URI 提取 key，在各容器本地查找
        local key="${archive_location#s3://*/}"
        for container in $(_get_archiver_containers); do
            if _check_local_file_in_container "$container" "$key"; then
                return 0
            fi
        done
        return 1
    fi

    # 本地路径：遍历所有归档容器查找
    for container in $(_get_archiver_containers); do
        if _check_local_file_in_container "$container" "$archive_location"; then
            return 0
        fi
    done

    # fallback: 尝试通过 S3 查找（当 S3 模式的归档容器写了非标准格式的 location 时）
    if _check_s3_file_by_local_key "$archive_location"; then
        return 0
    fi

    return 1
}

# 根据文件夹级 archive_location 拼接出 session 归档文件的完整路径
# archive_location 形如 "s3://bucket/prefix/run_id/" 或 "run_id/"
# 返回形如 "s3://bucket/prefix/run_id/session.jsonl.gz" 或 "run_id/session.jsonl.gz"
build_archive_file_path() {
    local archive_location="$1"
    local session_id="$2"
    local safe_session=$(echo "$session_id" | tr ',/' '__')
    local suffix=".jsonl.gz"

    echo "${archive_location}${safe_session}${suffix}"
}

# 验证归档文件内容（自动识别本地 / S3，支持多容器 fallback）
verify_archive_file() {
    local archive_location="$1"
    local expected_count="$2"

    local actual_count=""

    if _is_s3_uri "$archive_location"; then
        # S3 URI：在 S3 容器中下载并统计行数
        actual_count=$(docker exec "${ARCHIVER_CONTAINER_NAME}" python3 -c "
import boto3, gzip, os
from urllib.parse import urlparse
uri = '${archive_location}'
p = urlparse(uri)
bucket = p.netloc
key = p.path.lstrip('/')
ep = os.environ.get('AWS_ENDPOINT_URL')
kwargs = {}
if ep:
    kwargs['endpoint_url'] = ep
s3 = boto3.client('s3', **kwargs)
local_path = '/tmp/test_verify.gz'
s3.download_file(bucket, key, local_path)
with gzip.open(local_path, 'rt') as f:
    count = sum(1 for _ in f)
os.unlink(local_path)
print(count)
" 2>/dev/null)
    else
        # 本地路径：遍历所有归档容器查找
        for container in $(_get_archiver_containers); do
            actual_count=$(docker exec "${container}" python3 -c "
import gzip, os
path = '${archive_location}'
if not os.path.exists(path):
    print('')
else:
    with gzip.open(path, 'rt') as f:
        count = sum(1 for _ in f)
    print(count)
" 2>/dev/null)
            if [ -n "$actual_count" ]; then
                break
            fi
        done
    fi

    if [ -z "$actual_count" ] || [ "$actual_count" -ne "$expected_count" ]; then
        log_error "归档文件记录数不匹配: 期望 ${expected_count}, 实际 ${actual_count:-0}"
        return 1
    fi

    log_success "归档文件验证通过: ${archive_location} (${actual_count} 条记录)"
    return 0
}

# 读取归档文件第一行（自动识别本地 / S3，支持多容器 fallback）
read_archive_first_line() {
    local archive_location="$1"

    if _is_s3_uri "$archive_location"; then
        docker exec "${ARCHIVER_CONTAINER_NAME}" python3 -c "
import boto3, gzip, os
from urllib.parse import urlparse
uri = '${archive_location}'
p = urlparse(uri)
bucket = p.netloc
key = p.path.lstrip('/')
ep = os.environ.get('AWS_ENDPOINT_URL')
kwargs = {}
if ep:
    kwargs['endpoint_url'] = ep
s3 = boto3.client('s3', **kwargs)
local_path = '/tmp/test_read.gz'
s3.download_file(bucket, key, local_path)
with gzip.open(local_path, 'rt') as f:
    print(f.readline().strip())
os.unlink(local_path)
" 2>/dev/null
    else
        for container in $(_get_archiver_containers); do
            local line
            line=$(docker exec "${container}" python3 -c "
import gzip, os
path = '${archive_location}'
if os.path.exists(path):
    with gzip.open(path, 'rt') as f:
        print(f.readline().strip())
" 2>/dev/null)
            if [ -n "$line" ]; then
                echo "$line"
                return 0
            fi
        done
        return 1
    fi
}

# ========================================
# 归档执行函数
# ========================================

# 在归档容器内执行一次性归档（不启动调度器）
run_archive_once() {
    local retention_days="${1:-${ARCHIVE_RETENTION_DAYS}}"

    docker exec "${ARCHIVER_CONTAINER_NAME}" python3 -c "
import asyncio, sys
sys.path.insert(0, '/app')

import ray
from psycopg_pool import AsyncConnectionPool
from traj_archiver.config import get_database_url, get_archive_config, get_database_pool_config
from traj_archiver.storage import create_storage
from traj_archiver.archiver import archive_details
from traj_archiver.session_worker import SessionArchiveWorker

async def main():
    db_url = get_database_url()
    archive_config = get_archive_config()
    pool_config = get_database_pool_config()

    pool = AsyncConnectionPool(conninfo=db_url, **pool_config)
    await pool.open()

    storage = create_storage(archive_config)

    num_workers = archive_config.get('num_workers', 1)
    compress = archive_config.get('compress', True)
    local_temp_path = archive_config.get('local_temp_path', '/tmp/archives')

    ray.init(address='auto', ignore_reinit_error=True, log_to_driver=False)

    workers = []
    for i in range(num_workers):
        w = SessionArchiveWorker.remote(
            worker_id=i, db_url=db_url,
            storage_config=archive_config,
            temp_root=local_temp_path, compress=compress,
        )
        workers.append(w)

    workers, result = await archive_details(
        pool=pool, workers=workers, storage=storage,
        local_temp_path=local_temp_path,
        retention_days=${retention_days},
    )

    ray.shutdown()
    await pool.close()

    print(f'records_archived={result[\"records_archived\"]}')
    print(f'runs_processed={result[\"runs_processed\"]}')
    print(f'errors={len(result[\"errors\"])}')

asyncio.run(main())
" 2>&1
}

# ========================================
# 容器操作函数
# ========================================

# 获取归档容器日志
get_archiver_logs() {
    docker logs "${ARCHIVER_CONTAINER_NAME}" 2>&1
}

# 在归档容器日志中搜索特定模式
search_archiver_logs() {
    local pattern="$1"
    docker logs "${ARCHIVER_CONTAINER_NAME}" 2>&1 | grep -E "$pattern"
}

# 检查归档容器日志中是否包含特定模式
archiver_log_contains() {
    local pattern="$1"
    docker logs "${ARCHIVER_CONTAINER_NAME}" 2>&1 | grep -qE "$pattern"
}

# 获取业务容器日志（用于验证核心业务不包含归档代码）
get_proxy_logs() {
    docker logs "${PROXY_CONTAINER_NAME}" 2>&1
}

# 检查业务容器日志中是否包含归档相关内容
proxy_log_contains() {
    local pattern="$1"
    docker logs "${PROXY_CONTAINER_NAME}" 2>&1 | grep -qE "$pattern"
}
