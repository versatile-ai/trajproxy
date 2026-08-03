#!/bin/bash
# 场景 P211: 空 think 内容非流式场景（Proxy 层）
# 测试流程：启动mock服务 -> 注册模型(TITO+reasoning_parser) -> 发送非流式请求 ->
#           验证响应 content 干净（不含 <think>/</think> 标记）-> 删除模型
#
# 背景：模型推理输出 think 内容为空（如 <think></think>你好）时，
#       openai_builder 非流式路径若对 extract_reasoning 返回值做 truthy 检查，
#       空字符串 reasoning 会被跳过，导致 final_content 保留原始输出，
#       </think> 标记泄漏进 content。本场景用于防止该问题回归。
#
# 验证要点：
#   1. mock 返回 <think></think>你好（think 内容为空的模型输出）
#   2. 响应 content 必须为 "你好"，且不含 <think>/</think> 标记
#   3. reasoning 字段不要求非空（空 think 是合法场景）

# 获取脚本目录并加载utils
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils.sh"

echo "========================================"
echo "场景 P211: 空 think 内容非流式场景（Proxy 层）"
echo "========================================"
echo ""

# 测试配置
SCENARIO_ID=$(basename "${BASH_SOURCE[0]}" .sh | grep -oE '[A-Z][0-9]+' | tr '[:upper:]' '[:lower:]')
TEST_BASE_URL="${BASE_URL}"
TEST_MODEL_NAME="empty-think-model"  # mock 检测该名称触发空 think 输出
TEST_RUN_ID="run-${SCENARIO_ID}"
TEST_SESSION_ID="session-${SCENARIO_ID}-$(date +%s%N | md5sum | head -c 8)"
TEST_TOKENIZER_PATH="${DEFAULT_TOKENIZER_PATH}"

# Mock服务配置（端口递增，避免与 P201(19990), P202(19991), P204(19993/19994), P209(19995), P210(19996), P502(19997), P503(19998) 冲突）
MOCK_PORT=19999
MOCK_URL="http://127.0.0.1:${MOCK_PORT}"
MOCK_PID=""
MOCK_INFER_URL="http://${MOCK_INFER_HOST}:${MOCK_PORT}/v1"

# 确保退出时停止mock服务
trap stop_mock EXIT

# ========================================
# 步骤 1: 启动 Mock 推理服务
# ========================================
log_step "步骤 1: 启动 Mock 推理服务（端口 ${MOCK_PORT}）"

if ! start_mock; then
    assert_fail "Mock服务启动失败"
    print_summary
    exit 1
fi

echo ""

# ========================================
# 步骤 2: 注册模型（TITO + reasoning_parser）
# ========================================
log_step "步骤 2: 注册模型（run_id: ${TEST_RUN_ID}, model: ${TEST_MODEL_NAME}, token_in_token_out: true, reasoning_parser: ${DEFAULT_REASONING_PARSER}）"

REGISTER_RESPONSE=$(curl_with_log -s -w "\n%{http_code}" -X POST "${TEST_BASE_URL}/models/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"run_id\": \"${TEST_RUN_ID}\",
        \"model_name\": \"${TEST_MODEL_NAME}\",
        \"url\": \"${MOCK_INFER_URL}\",
        \"api_key\": \"${TEST_MODEL_API_KEY}\",
        \"tokenizer_path\": \"${TEST_TOKENIZER_PATH}\",
        \"token_in_token_out\": true,
        \"reasoning_parser\": \"${DEFAULT_REASONING_PARSER}\"
    }")

REGISTER_BODY=$(echo "$REGISTER_RESPONSE" | sed '$d')
REGISTER_STATUS=$(echo "$REGISTER_RESPONSE" | sed -n '$p')

assert_http_status "200" "$REGISTER_STATUS" "注册模型 HTTP 状态码应为 200"

REGISTER_RESULT=$(json_get "$REGISTER_BODY" "status")
assert_eq "success" "$REGISTER_RESULT" "注册模型应返回 success"
sleep 1

echo ""

# ========================================
# 步骤 3: 发送非流式请求（空 think 场景）
# ========================================
log_step "步骤 3: 发送非流式请求（session_id: ${TEST_SESSION_ID}）"

CHAT_RESPONSE=$(curl_with_log -s -w "\n%{http_code}" -X POST "${TEST_BASE_URL}/s/${TEST_RUN_ID}/${TEST_SESSION_ID}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${CHAT_API_KEY}" \
    -d "{
        \"model\": \"${TEST_MODEL_NAME}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"empty think test\"}],
        \"stream\": false,
        \"max_tokens\": 64
    }")

CHAT_BODY=$(echo "$CHAT_RESPONSE" | sed '$d')
CHAT_STATUS=$(echo "$CHAT_RESPONSE" | sed -n '$p')

assert_http_status "200" "$CHAT_STATUS" "非流式请求 HTTP 状态码应为 200"

# 提取 content 和 reasoning 字段
CONTENT_EXTRACT=$(echo "$CHAT_BODY" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
msg = data['choices'][0]['message']
content = msg.get('content', '') or ''
reasoning = msg.get('reasoning_content', '') or msg.get('reasoning', '') or ''
print(json.dumps({'content': content, 'reasoning': reasoning}, ensure_ascii=False))
" 2>/dev/null)

CHAT_CONTENT=$(echo "$CONTENT_EXTRACT" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['content'])" 2>/dev/null)
CHAT_REASONING=$(echo "$CONTENT_EXTRACT" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['reasoning'])" 2>/dev/null)

log_info "响应 content: ${CHAT_CONTENT}"
log_info "响应 reasoning: ${CHAT_REASONING}"

# 核心断言 1: content 不得包含 think 标记（回归防护点）
if echo "$CHAT_CONTENT" | grep -q "</think>\|<think>"; then
    assert_fail "content 包含 think 标记（空 think 泄漏）: ${CHAT_CONTENT}"
else
    TESTS_TOTAL=$((TESTS_TOTAL + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    log_success "content 不含 think 标记，通过"
fi

# 核心断言 2: content 应为 mock 输出的内容部分（你好）
if [ "$CHAT_CONTENT" = "你好" ]; then
    TESTS_TOTAL=$((TESTS_TOTAL + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    log_success "content 与预期一致（你好），通过"
else
    assert_fail "content 与预期不一致，期望 '你好'，实际: ${CHAT_CONTENT}"
fi

echo ""

# ========================================
# 步骤 4: 删除模型
# ========================================
log_step "步骤 4: 删除模型（run_id: ${TEST_RUN_ID}）"

DELETE_RESPONSE=$(curl_with_log -s -w "\n%{http_code}" -X DELETE "${TEST_BASE_URL}/models?model_name=${TEST_MODEL_NAME}&run_id=${TEST_RUN_ID}")

DELETE_BODY=$(echo "$DELETE_RESPONSE" | sed '$d')
DELETE_STATUS=$(echo "$DELETE_RESPONSE" | sed -n '$p')

assert_http_status "200" "$DELETE_STATUS" "删除模型 HTTP 状态码应为 200"

DELETE_RESULT=$(json_get "$DELETE_BODY" "status")
assert_eq "success" "$DELETE_RESULT" "删除模型应返回 success"

echo ""

# 打印测试摘要
print_summary
