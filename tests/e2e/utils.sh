#!/bin/bash
# 公共工具函数

# 导入配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# 测试计数器
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_step() {
    echo -e "${YELLOW}[STEP]${NC} $1"
}

# 失败日志记录函数：将失败信息写入 FAILURE_LOG 临时文件
# 格式: 场景名|失败消息|详情
log_failure() {
    if [ -n "${FAILURE_LOG:-}" ] && [ -w "${FAILURE_LOG:-}" ]; then
        echo "${FAILURE_CONTEXT:-unknown}|$1|$2" >> "$FAILURE_LOG"
    fi
}

# 断言函数：相等
assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ "$expected" == "$actual" ]; then
        log_success "$message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$message"
        echo "    期望: $expected"
        echo "    实际: $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_failure "$message" "期望: ${expected}, 实际: ${actual}"
        return 1
    fi
}

# 断言函数：包含
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [[ "$haystack" == *"$needle"* ]]; then
        log_success "$message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$message"
        echo "    未找到: $needle"
        echo "    内容: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_failure "$message" "未找到: ${needle}"
        return 1
    fi
}

# 断言函数：不包含
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [[ "$haystack" != *"$needle"* ]]; then
        log_success "$message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$message"
        echo "    不应包含: $needle"
        echo "    内容: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_failure "$message" "不应包含: ${needle}"
        return 1
    fi
}

# 断言函数：HTTP 状态码
assert_http_status() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    assert_eq "$expected" "$actual" "$message"
}

# 断言函数：无条件失败（用于复杂条件判断后的失败报告）
# 用法: assert_fail "消息" ["详情"]
# 示例: assert_fail "响应中无 tool_calls 字段"
#       assert_fail "重复注册返回异常状态" "实际: 400"
assert_fail() {
    local message="$1"
    local detail="${2:-}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_error "$message"
    [ -n "$detail" ] && echo "    $detail"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    log_failure "$message" "$detail"
    return 1
}

# 断言函数：实际值应为期望值列表之一
# 用法: assert_one_of "$actual" "200 409" "消息"
# 示例: assert_one_of "$STATUS" "200 409" "重复注册应返回 200/409"
assert_one_of() {
    local actual="$1"
    local expected_list="$2"
    local message="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    local found=false
    for expected in $expected_list; do
        if [ "$actual" == "$expected" ]; then
            found=true
            break
        fi
    done

    if $found; then
        log_success "$message (实际: $actual)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$message"
        echo "    期望之一: $expected_list"
        echo "    实际: $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_failure "$message" "期望之一: ${expected_list}, 实际: ${actual}"
        return 1
    fi
}

# 打印 curl 命令（格式化输出）
log_curl_cmd() {
    echo -e "${BLUE}[CMD]${NC}"
    echo "$1" | fold -s -w 100
}

# 打印响应结果（格式化 JSON，确保 Unicode 正确显示）
log_response() {
    if [[ "$1" == "HTTP Status:"* ]]; then
        echo -e "${BLUE}[RES]${NC} $1"
    else
        echo -e "${BLUE}[RES]${NC}"
        echo "$1" | python3 -c "
import sys
import json
data = sys.stdin.read()
try:
    obj = json.loads(data)
    print(json.dumps(obj, indent=4, ensure_ascii=False))
except:
    print(data)
"
    fi
}

# 分离响应体和状态码（兼容 macOS）
split_response() {
    local response="$1"
    # 使用 sed 删除最后一行获取 body，获取最后一行获取状态码
    RESPONSE_BODY=$(echo "$response" | sed '$d')
    RESPONSE_STATUS=$(echo "$response" | sed -n '$p')
}

# 打印分隔线
log_separator() {
    echo "----------------------------------------"
}

# ========================================
# HTTP请求封装函数：自动打印curl命令、响应结果、请求耗时
# ========================================
# 所有日志输出到stderr，不影响stdout返回值（与原始curl行为一致）
# 用法: curl_with_log [curl参数...]
# 示例: RESPONSE=$(curl_with_log -s -w "\n%{http_code}" -X POST "url" ...)
#       curl_with_log -s -X DELETE "url" > /dev/null        # 仅看日志，丢弃stdout
# 注意: 内部调用(健康检查/mock服务)请使用 command curl 跳过日志
curl_with_log() {
    local start_ms
    start_ms=$(python3 -c "import time; print(int(time.time()*1000))")

    local response
    response=$(command curl "$@")
    local curl_exit=$?

    local end_ms
    end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    local duration=$((end_ms - start_ms))

    # 检测 -w/--write-out 参数（含HTTP状态码的响应模式）
    local has_w=false
    for arg in "$@"; do
        if [[ "$arg" == "-w" ]] || [[ "$arg" == "--write-out" ]]; then
            has_w=true
            break
        fi
        if [[ "$arg" == -w* ]] && [[ "$arg" != "-w" ]]; then
            has_w=true
            break
        fi
        if [[ "$arg" == --write-out=* ]]; then
            has_w=true
            break
        fi
    done

    # 构建可读curl命令字符串（含空格/花括号的参数加单引号）
    local curl_cmd=""
    for arg in "$@"; do
        case "$arg" in
            *' '*) curl_cmd="${curl_cmd} '${arg}'" ;;
            *'{'*) curl_cmd="${curl_cmd} '${arg}'" ;;
            *'}'*) curl_cmd="${curl_cmd} '${arg}'" ;;
            *)     curl_cmd="${curl_cmd} ${arg}" ;;
        esac
    done

    # 日志全部输出到stderr
    >&2 echo -e "${BLUE}[CURL]${NC} curl${curl_cmd}"

    if $has_w; then
        # 含状态码模式：分离body和status
        local body
        body=$(echo "$response" | sed '$d')
        local status
        status=$(echo "$response" | sed -n '$p')
        >&2 echo -e "${BLUE}[RES]${NC} HTTP Status: ${status}"
        if [ -n "$body" ]; then
            local line_count
            line_count=$(echo "$body" | wc -l | tr -d ' ')
            if [ "$line_count" -gt 30 ]; then
                >&2 echo -e "${BLUE}[RES]${NC} 响应过长 (${line_count}行)，仅显示前10行:"
                echo "$body" | head -10 >&2
                >&2 echo "    ... 省略中间内容 ..."
            else
                >&2 log_response "${body}"
            fi
        fi
    else
        # 简单模式：直接记录响应
        if [ -n "$response" ]; then
            local line_count
            line_count=$(echo "$response" | wc -l | tr -d ' ')
            if [ "$line_count" -gt 30 ]; then
                >&2 echo -e "${BLUE}[RES]${NC} 响应过长 (${line_count}行)，仅显示前5行和最后5行:"
                echo "$response" | head -5 >&2
                >&2 echo "    ... 省略中间 $(($line_count - 10)) 行 ..."
                echo "$response" | tail -5 >&2
            else
                >&2 log_response "${response}"
            fi
        fi
    fi

    >&2 echo -e "${YELLOW}[TIME]${NC} ${duration}ms"
    >&2 log_separator

    # 完整响应写入日志（不截断，供离线分析使用）
    # 当 FULL_RESPONSE_LOG 被设置时（由 _run_single_scenario 设置），把原始响应追加写入
    if [ -n "${FULL_RESPONSE_LOG:-}" ]; then
        {
            echo ""
            echo "────────── [$(_e2e_hms)] curl${curl_cmd} ──────────"
            echo "$response"
        } >> "$FULL_RESPONSE_LOG"
    fi

    # 返回原始响应到stdout（与原始curl行为一致）
    echo "$response"
    return $curl_exit
}

# 时间戳：HH:MM:SS（用于完整响应日志标头，避免频繁调用 date 产生子进程开销）
_e2e_hms() {
    date +%H:%M:%S
}

# 提取 JSON 字段值（使用 grep 和 sed，不依赖 jq）
json_get() {
    local json="$1"
    local key="$2"

    # 使用 grep 和 sed 提取值
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/\"$key\"[[:space:]]*:[[:space:]]*\"//" | sed 's/"$//' | head -1
}

# 提取 JSON 字段值（数字类型）
json_get_number() {
    local json="$1"
    local key="$2"

    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" | sed "s/\"$key\"[[:space:]]*:[[:space:]]*//" | head -1
}

# 提取 JSON 字段值（布尔类型）
json_get_bool() {
    local json="$1"
    local key="$2"

    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[a-z]*" | sed "s/\"$key\"[[:space:]]*:[[:space:]]*//" | head -1
}

# 打印测试摘要
print_summary() {
    echo ""
    echo "========================================"
    echo "测试摘要"
    echo "========================================"
    echo -e "总计: ${TESTS_TOTAL}"
    echo -e "通过: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "失败: ${RED}${TESTS_FAILED}${NC}"
    echo "========================================"

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}所有测试通过！${NC}"
        return 0
    else
        echo -e "${RED}存在失败的测试！${NC}"
        return 1
    fi
}

# ========================================
# 缓存命中校验辅助函数
# ========================================

# 验证缓存命中递增和 token_ids 长度校验
# 参数: $1 - session_id
#        $2 - 期望轮次数
#        $3 - 验证模式: incremental(正常递增), nosession(恒为0), kwargs_change(第2轮失效), tools_change(第2轮失效)
verify_cache_incremental() {
    local session_id="$1"
    local expected_rounds="$2"
    local verify_mode="${3:-incremental}"

    log_step "验证缓存命中 (${verify_mode})"

    TRAJ=$(curl_with_log -s "${BASE_URL}/trajectory?session_id=${session_id}&limit=10")

    local tmpfile=$(mktemp)
    echo "$TRAJ" > "$tmpfile"

    local result=$(python3 -c "
import json, sys

with open('$tmpfile', 'r') as f:
    data = json.loads(f.read())

records = data.get('records', [])
if len(records) < $expected_rounds:
    print(f'FAIL:轨迹记录数不足, 期望>=${expected_rounds}, 实际:{len(records)}')
    sys.exit(0)

sorted_recs = sorted(records, key=lambda r: r.get('start_time', ''))

errors = []

for i, rec in enumerate(sorted_recs):
    round_num = i + 1
    cache_hit = rec.get('cache_hit_tokens', -1)
    full_conv_ids = rec.get('full_conversation_token_ids', [])
    token_ids = rec.get('token_ids', [])
    response_ids = rec.get('response_ids', [])

    # 校验2: len(full_conversation_token_ids) == len(token_ids) + len(response_ids)
    if full_conv_ids and token_ids and response_ids:
        if len(full_conv_ids) != len(token_ids) + len(response_ids):
            errors.append(f'R{round_num}校验2: full_conv={len(full_conv_ids)} != token_ids={len(token_ids)}+response_ids={len(response_ids)}={len(token_ids)+len(response_ids)}')

    if '$verify_mode' == 'nosession':
        if cache_hit != 0:
            errors.append(f'R{round_num}: cache_hit={cache_hit}, 期望=0(无session)')
    elif '$verify_mode' == 'kwargs_change':
        if round_num == 1:
            if cache_hit != 0:
                errors.append(f'R1: cache_hit={cache_hit}, 期望=0')
        else:
            if cache_hit != 0:
                errors.append(f'R{round_num}: cache_hit={cache_hit}, 期望=0(kwargs变更)')
    elif '$verify_mode' == 'tools_change':
        if round_num == 1:
            if cache_hit != 0:
                errors.append(f'R1: cache_hit={cache_hit}, 期望=0')
        else:
            if cache_hit != 0:
                errors.append(f'R{round_num}: cache_hit={cache_hit}, 期望=0(tools变更)')
    elif '$verify_mode' == 'incremental':
        if round_num == 1:
            if cache_hit != 0:
                errors.append(f'R1校验1: cache_hit={cache_hit}, 期望=0')
        else:
            prev_ids = sorted_recs[i-1].get('full_conversation_token_ids', [])
            expected = len(prev_ids)
            if cache_hit != expected:
                errors.append(f'R{round_num}校验1: cache_hit={cache_hit}, 期望={expected}')

if errors:
    print('FAIL:' + '; '.join(errors))
else:
    summary = []
    for i, rec in enumerate(sorted_recs):
        ch = rec.get('cache_hit_tokens', '?')
        fl = len(rec.get('full_conversation_token_ids', []))
        ti = len(rec.get('token_ids', []))
        ri = len(rec.get('response_ids', []))
        summary.append(f'R{i+1}:cache_hit={ch},full_conv={fl},token_ids={ti},response_ids={ri}')
    print('PASS:' + ', '.join(summary))
" 2>/dev/null)

    rm -f "$tmpfile"

    if echo "$result" | grep -q "^PASS:"; then
        log_success "$result"
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "$result"
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_failure "${result#FAIL:}" ""
    fi
}

# ========================================
# Layer 内并发执行场景
# ========================================
# 参数: $1 = layer_name（如 nginx, proxy）
#        $2 = layer_dir（layer 根目录，scenarios 目录在其下）
#        $3... = 场景 ID 列表（可为空，空则扫描目录下全部 .sh）
#
# 环境变量:
#   E2E_JOBS    - 并发数，默认 1（串行，向后兼容）
#   E2E_LOG_DIR - 日志落盘根目录（由 run_tests.sh 创建；单独调用 run_layer.sh 时按需创建）
#   TIMING_LOG  - 计时日志临时文件（顶层 run_tests.sh 创建，子进程 >> 追加，POSIX 短行原子安全）
#   FAILURE_LOG - 失败日志临时文件（同上）
#
# 行为:
#   - 实时输出到终端（并发场景的输出会交错，这是预期行为，彩色保留）
#   - 并发模式下同时 tee 到日志文件，文件名按场景编号排序
#     目录: ${E2E_LOG_DIR}/${layer_name}/
#     文件: ${seq_num:03d}_${scenario_name}.log
#   - 完成后打印层 summary（通过/失败数）
#   - 返回值: 0=全部通过，1=存在失败（供 run_layer.sh 用作退出码）
#
# 并发控制: FIFO 信号量（纯 Bash，兼容 macOS Bash 3.x）
run_scenarios_parallel() {
    local layer_name="$1"
    local layer_dir="$2"
    shift 2
    local scenario_ids=("$@")
    local scenarios_dir="${layer_dir}/scenarios"

    # 并发度,默认 1（串行）
    local jobs="${E2E_JOBS:-1}"
    # 日志落盘目录
    local log_dir="${E2E_LOG_DIR:-}"

    # 如果没有指定场景 ID，扫描目录下所有 .sh，按文件名顺序提取 ID
    if [ ${#scenario_ids[@]} -eq 0 ]; then
        for f in "${scenarios_dir}"/*.sh; do
            if [ -f "$f" ]; then
                local name=$(basename "$f" .sh)
                local id=$(echo "$name" | cut -d'_' -f1)
                scenario_ids+=("$id")
            fi
        done
    fi

    local total=${#scenario_ids[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}[${layer_name}] 无匹配场景,跳过${NC}"
        return 0
    fi

    # ========================================
    # 串行模式（jobs<=1 或仅 1 个场景）
    # 行为：原串行执行 + 若 E2E_LOG_DIR 存在则也落盘（统一日志行为）
    # ========================================
    if [ "$jobs" -le 1 ] || [ "$total" -le 1 ]; then
        local passed=0
        local failed=0
        # 若 E2E_LOG_DIR 存在，串行模式也落盘到 layer 子目录
        local serial_log_dir=""
        if [ -z "$log_dir" ]; then
            # 按需创建 E2E_LOG_DIR
            if [ -n "${E2E_LOG_DIR:-}" ] && [ -d "${E2E_LOG_DIR}" ]; then
                log_dir="${E2E_LOG_DIR}"
            else
                log_dir="$(cd "${SCRIPT_DIR}/../.." && pwd)/logs/tests/$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$log_dir"
                export E2E_LOG_DIR="$log_dir"
                echo -e "${BLUE}[${layer_name}] 日志目录: ${log_dir}${NC}"
            fi
        fi
        serial_log_dir="${log_dir}/${layer_name}"
        mkdir -p "$serial_log_dir"

        local serial_idx=0
        for scenario_id in "${scenario_ids[@]}"; do
            serial_idx=$((serial_idx + 1))
            local matched_files=("${scenarios_dir}/${scenario_id}_"*".sh")
            if [ ! -f "${matched_files[0]}" ]; then
                echo -e "${RED}[${layer_name}] 错误: 找不到场景 ${scenario_id}${NC}"
                failed=$((failed + 1))
                continue
            fi
            local sn=$(basename "${matched_files[0]}" .sh)
            local log_file="${serial_log_dir}/$(printf '%03d' $serial_idx)_${sn}.log"
            # 注意：不能用 `if cmd | tee` 直接判断（无 pipefail 时退出码来自 tee），
            # 失败场景会被误计为通过。与并发模式一致，显式取 PIPESTATUS[0]。
            _run_single_scenario "$layer_name" "${matched_files[0]}" "$log_file" 2>&1 | tee "$log_file"
            local scenario_rc=${PIPESTATUS[0]}
            if [ "$scenario_rc" -eq 0 ]; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
            fi
        done
        _print_layer_summary "$layer_name" $passed $failed $total
        [ $failed -gt 0 ] && return 1
        return 0
    fi

    # ========================================
    # 并发模式（jobs > 1）
    # ========================================
    echo -e "${BLUE}[${layer_name}] 启动并发执行: ${total} 个场景, 并发度 ${jobs}${NC}"

    # 若 run_layer.sh 被单独调用，E2E_LOG_DIR 可能不存在，按需创建
    # 路径: <项目根>/logs/tests/YYYYMMDD_HHMMSS/（SCRIPT_DIR 在 utils.sh 中为 tests/e2e）
    if [ -z "$log_dir" ]; then
        log_dir="$(cd "${SCRIPT_DIR}/../.." && pwd)/logs/tests/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$log_dir"
        export E2E_LOG_DIR="$log_dir"
        echo -e "${BLUE}[${layer_name}] 日志目录: ${log_dir}${NC}"
    fi
    local layer_log_dir="${log_dir}/${layer_name}"
    mkdir -p "$layer_log_dir"

    # 状态目录（用于跨子进程传递 PASS/FAIL 状态）
    local state_dir=$(mktemp -d /tmp/e2e_state_XXXXXX)

    # FIFO 信号量：控制同时运行不超过 jobs 个场景
    local fifo="${state_dir}/.fifo"
    mkfifo "$fifo"
    exec 3<>"$fifo"
    # 预填充 N 个令牌
    local i
    for ((i = 0; i < jobs; i++)); do
        echo >&3
    done

    local pids=()
    local scenario_idx=0

    for scenario_id in "${scenario_ids[@]}"; do
        scenario_idx=$((scenario_idx + 1))
        local matched_files=("${scenarios_dir}/${scenario_id}_"*".sh")

        if [ ! -f "${matched_files[0]}" ]; then
            echo -e "${RED}[${layer_name}] 错误: 找不到场景 ${scenario_id}${NC}"
            echo "FAIL" > "${state_dir}/${scenario_idx}_${scenario_id}.status"
            continue
        fi

        local scenario_file="${matched_files[0]}"
        local scenario_name=$(basename "$scenario_file" .sh)
        local state_file="${state_dir}/${scenario_idx}_${scenario_id}.status"
        local log_file="${layer_log_dir}/$(printf '%03d' $scenario_idx)_${scenario_name}.log"

        # 获取一个令牌（无可用令牌时阻塞等待）
        read -u 3 -r _token

        (
            # 子 shell 执行单个场景
            local exit_code=0
            _run_single_scenario "$layer_name" "$scenario_file" "$log_file" 2>&1 | tee "$log_file"
            exit_code=${PIPESTATUS[0]}

            if [ $exit_code -eq 0 ]; then
                echo "PASS" > "$state_file"
            else
                echo "FAIL" > "$state_file"
            fi

            # 归还令牌
            echo >&3
        ) &
        pids+=($!)
    done

    # 等待所有后台任务完成
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # 关闭 FIFO
    exec 3>&-
    rm -f "$fifo"

    # 统计结果
    local passed=0
    local failed=0
    for status_file in "${state_dir}"/*.status; do
        if [ -f "$status_file" ]; then
            local status=$(cat "$status_file")
            if [ "$status" = "PASS" ]; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done

    rm -rf "$state_dir"

    _print_layer_summary "$layer_name" $passed $failed $total
    [ $failed -gt 0 ] && return 1
    return 0
}

# 单个场景执行包装（供 run_scenarios_parallel 调用）
# 参数: $1 = layer_name, $2 = scenario_file, $3 = log_file（可选，scenario 主日志路径）
# 输出: 场景的全部 stdout/stderr（直通终端 + tee 落盘）
# 副作用:
#   - 写 TIMING_LOG（POSIX 短行 >> 追加原子安全,并发写入不会损坏）
#   - 若提供 log_file,scenario 运行期间所有 curl_with_log 调用的完整响应
#     会先写入 ${log_file}.full,执行结束后合并到 log_file 末尾（流式响应不省略）
_run_single_scenario() {
    local layer_name="$1"
    local scenario_file="$2"
    local log_file="${3:-}"
    local scenario_name=$(basename "$scenario_file" .sh)

    echo ""
    echo "========================================"
    echo -e "${BLUE}[${layer_name}] 运行场景: ${scenario_name}${NC}"
    echo "========================================"

    # 设置完整响应日志文件（scenario 运行期间，curl_with_log 会把原始完整响应
    # 追加写入该文件；执行结束后会被合并到 scenario 主日志末尾）
    local full_resp_log=""
    if [ -n "$log_file" ]; then
        full_resp_log="${log_file}.full"
        : > "$full_resp_log"
        export FULL_RESPONSE_LOG="$full_resp_log"
    else
        unset FULL_RESPONSE_LOG 2>/dev/null || true
    fi

    export FAILURE_CONTEXT="${scenario_name}"
    local start_ts=$(date +%s)
    local exit_code=0
    if bash "$scenario_file"; then
        exit_code=0
        local end_ts=$(date +%s)
        local duration=$((end_ts - start_ts))
        echo -e "${GREEN}场景 ${scenario_name} 耗时: ${duration}s${NC}"
        if [ -n "${TIMING_LOG:-}" ] && [ -w "${TIMING_LOG:-}" ]; then
            echo "${scenario_name}|${duration}" >> "$TIMING_LOG"
        fi
    else
        exit_code=1
        local end_ts=$(date +%s)
        local duration=$((end_ts - start_ts))
        echo -e "${RED}场景 ${scenario_name} 耗时: ${duration}s (失败)${NC}"
        if [ -n "${TIMING_LOG:-}" ] && [ -w "${TIMING_LOG:-}" ]; then
            echo "${scenario_name}|${duration}" >> "$TIMING_LOG"
        fi
    fi

    # 把完整响应日志追加到 scenario 主日志（流式返回不省略，供离线分析）
    if [ -n "$full_resp_log" ] && [ -f "$full_resp_log" ] && [ -s "$full_resp_log" ]; then
        {
            echo ""
            echo "========================================"
            echo "[完整响应日志 - 流式返回未省略,供离线分析]"
            echo "========================================"
            cat "$full_resp_log"
        } >> "$log_file"
        rm -f "$full_resp_log"
    elif [ -n "$full_resp_log" ] && [ -f "$full_resp_log" ]; then
        rm -f "$full_resp_log"
    fi

    unset FULL_RESPONSE_LOG 2>/dev/null || true
    return $exit_code
}

# 打印 Layer 执行摘要
# 参数: $1 = layer_name, $2 = passed, $3 = failed, $4 = total
_print_layer_summary() {
    local layer_name="$1"
    local passed=$2
    local failed=$3
    local total=$4
    echo ""
    echo "========================================"
    echo "[${layer_name}] 测试总结"
    echo "========================================"
    echo -e "场景总计: ${total}"
    echo -e "场景通过: ${GREEN}${passed}${NC}"
    echo -e "场景失败: ${RED}${failed}${NC}"
    echo "========================================"
}
