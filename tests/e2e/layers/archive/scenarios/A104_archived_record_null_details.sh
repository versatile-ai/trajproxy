#!/bin/bash
# 场景 A104: 归档后 Record 详情 NULL 字段验证（Archive 层）
# 验证归档后 GET /trajectories/{session_id}/records/{request_id} 返回的详情字段为 null
# 核心契约：归档记录仅元数据可查，详情字段一律 null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils.sh"

echo "========================================"
echo "场景 A104: 归档后 Record 详情 NULL 字段验证"
echo "========================================"
echo ""

TEST_SESSION="test_archive_a104_$(date +%s)"
TEST_RUN="test-run-a104"
MONTH_LAST=$(date -d "last month" +%Y_%m 2>/dev/null || date -v-1m +%Y_%m 2>/dev/null || echo "2026_04")
TEST_REQUEST_ID="req_1"

# ============================================================
# 步骤 1: 创建过期分区并插入测试数据
# ============================================================
log_step "步骤 1: 创建过期分区并插入测试数据"

create_partition "${MONTH_LAST}"

# 插入含完整详情字段的测试数据（确保归档前各详情字段非空，归档后才能验证 NULL 补全）
UNIQUE_ID="${TEST_SESSION},${TEST_REQUEST_ID}"
CREATED_AT="${MONTH_LAST:0:4}-${MONTH_LAST:5:2}-15 10:00:00"

db_execute "
    INSERT INTO request_metadata (
        unique_id, request_id, session_id, run_id, model,
        prompt_tokens, completion_tokens, total_tokens,
        cache_hit_tokens, processing_duration_ms,
        start_time, end_time, created_at, error
    ) VALUES (
        '${UNIQUE_ID}', '${TEST_REQUEST_ID}', '${TEST_SESSION}', '${TEST_RUN}', '${TEST_MODEL_NAME}',
        100, 50, 150, 0, 500.0,
        '${CREATED_AT}', '${CREATED_AT}', '${CREATED_AT}', NULL
    )
    ON CONFLICT (unique_id) DO NOTHING;
"

db_execute "
    INSERT INTO request_details_active (
        unique_id, created_at, tokenizer_path, messages,
        raw_request, raw_response,
        text_request, text_response,
        prompt_text, token_ids,
        token_request, token_response,
        response_text, response_ids,
        full_conversation_text, full_conversation_token_ids,
        error_traceback
    ) VALUES (
        '${UNIQUE_ID}', '${CREATED_AT}', 'test-tokenizer',
        '[{\"role\":\"user\",\"content\":\"test\"}]'::json,
        '{\"model\":\"test\"}'::json,
        '{\"choices\":[]}'::json,
        '{\"text\":\"req\"}'::json,
        '{\"text\":\"resp\"}'::json,
        'test prompt text',
        ARRAY[1, 2, 3],
        '{\"token_ids\":[1,2,3]}'::json,
        '{\"token_ids\":[4,5,6]}'::json,
        'test response text',
        ARRAY[4, 5, 6],
        'test full conversation text',
        ARRAY[1, 2, 3, 4, 5, 6],
        NULL
    )
    ON CONFLICT DO NOTHING;
"

log_info "已插入完整详情测试数据: session=${TEST_SESSION}, request_id=${TEST_REQUEST_ID}"

# ============================================================
# 步骤 2: 归档前基线 — 验证详情字段非空
# ============================================================
log_step "步骤 2: 归档前基线 — 查询单条详情"

BASELINE_RESPONSE=$(curl_with_log -s -w "\n%{http_code}" -X GET "${BASE_URL}/trajectories/${TEST_SESSION}/records/${TEST_REQUEST_ID}")

BASELINE_BODY=$(echo "$BASELINE_RESPONSE" | sed '$d')
BASELINE_STATUS=$(echo "$BASELINE_RESPONSE" | sed -n '$p')

assert_http_status "200" "$BASELINE_STATUS" "归档前查询应返回 200"

BASELINE_CHECK=$(echo "$BASELINE_BODY" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
errors = []

messages = data.get('messages')
if not messages or not isinstance(messages, list) or len(messages) == 0:
    errors.append('归档前 messages 应为非空数组')

if data.get('archive_location') is not None:
    errors.append(f'归档前 archive_location 应为 null，实际: {data.get(\"archive_location\")}')

if errors:
    print('FAIL:' + '; '.join(errors))
else:
    print(f'PASS:归档前 messages非空, archive_location=null')
" 2>/dev/null)

if echo "$BASELINE_CHECK" | grep -q "^PASS:"; then
    log_success "$BASELINE_CHECK"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_fail "$BASELINE_CHECK"
fi
echo ""

# ============================================================
# 步骤 3: 执行归档（retention_days=1，上月数据全部过期）
# ============================================================
log_step "步骤 3: 执行归档（retention_days=1）"

ARCHIVE_OUTPUT=$(run_archive_once 1 2>&1)
log_info "归档输出:"
echo "$ARCHIVE_OUTPUT" | tail -3

sleep 0.3

# ============================================================
# 步骤 4: 归档后查询单条详情 — 验证详情字段一律为 null（核心契约）
# ============================================================
log_step "步骤 4: 归档后查询单条详情 — 验证详情字段为 null"

ARCHIVED_RESPONSE=$(curl_with_log -s -w "\n%{http_code}" -X GET "${BASE_URL}/trajectories/${TEST_SESSION}/records/${TEST_REQUEST_ID}")

ARCHIVED_BODY=$(echo "$ARCHIVED_RESPONSE" | sed '$d')
ARCHIVED_STATUS=$(echo "$ARCHIVED_RESPONSE" | sed -n '$p')

assert_http_status "200" "$ARCHIVED_STATUS" "归档后查询应返回 200"

ARCHIVED_CHECK=$(echo "$ARCHIVED_BODY" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
errors = []

# 元数据字段应保持正常值
if data.get('model') != '${TEST_MODEL_NAME}':
    errors.append(f'model 应为 ${TEST_MODEL_NAME}，实际: {data.get(\"model\")}')

if data.get('prompt_tokens') != 100:
    errors.append(f'prompt_tokens 应为 100，实际: {data.get(\"prompt_tokens\")}')

if data.get('start_time') is None:
    errors.append('start_time 不应为 null')

# archive_location 应非空（已归档）
if data.get('archive_location') is None:
    errors.append('archive_location 应非空（已归档）')

# 详情字段应一律为 null（核心契约）
detail_fields = [
    'messages', 'raw_request', 'raw_response',
    'text_request', 'text_response',
    'prompt_text', 'token_ids', 'token_request', 'token_response',
    'response_text', 'response_ids',
    'full_conversation_text', 'full_conversation_token_ids',
    'error_traceback', 'tokenizer_path'
]
null_violations = []
for field in detail_fields:
    val = data.get(field)
    if val is not None:
        null_violations.append(f'{field}={val!r:.50}')

if null_violations:
    errors.append('以下详情字段应为 null 但实际非空: ' + '; '.join(null_violations))

if errors:
    print('FAIL:' + '; '.join(errors))
else:
    loc = data.get('archive_location', '')
    print(f'PASS:元数据正常, archive_location={loc[:40]}, 详情字段全部为null')
" 2>/dev/null)

if echo "$ARCHIVED_CHECK" | grep -q "^PASS:"; then
    log_success "$ARCHIVED_CHECK"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_fail "$ARCHIVED_CHECK"
fi
echo ""

# ============================================================
# 步骤 5: 验证列表接口也显示归档状态
# ============================================================
log_step "步骤 5: 验证列表接口显示归档状态"

LIST_RESPONSE=$(curl_with_log -s -w "\n%{http_code}" -X GET "${BASE_URL}/trajectories/${TEST_SESSION}/records")

LIST_BODY=$(echo "$LIST_RESPONSE" | sed '$d')
LIST_STATUS=$(echo "$LIST_RESPONSE" | sed -n '$p')

assert_http_status "200" "$LIST_STATUS" "列表查询应返回 200"

LIST_CHECK=$(echo "$LIST_BODY" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
records = data.get('records', [])
errors = []

if not records:
    errors.append('列表应包含归档记录')
else:
    rec = records[0]
    if rec.get('archive_location') is None:
        errors.append('列表中 archive_location 应非空')
    if 'messages' in rec:
        errors.append('列表不应包含详情字段 messages')

if errors:
    print('FAIL:' + '; '.join(errors))
else:
    print('PASS:列表含归档记录, archive_location非空, 不含详情字段')
" 2>/dev/null)

if echo "$LIST_CHECK" | grep -q "^PASS:"; then
    log_success "$LIST_CHECK"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_fail "$LIST_CHECK"
fi
echo ""

# ============================================================
# 步骤 6: 清理测试数据
# ============================================================
log_step "步骤 6: 清理测试数据"
cleanup_test_data "${TEST_SESSION}"

echo ""

# ============================================================
# 打印测试摘要
# ============================================================
print_summary
