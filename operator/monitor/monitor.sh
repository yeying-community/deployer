#!/usr/bin/env bash
# Monitor service error logs and send notifications

set -euo pipefail
shopt -s nullglob

script_dir=$(cd "$(dirname "$0")" || exit 1; pwd)
# shellcheck disable=SC1091
source "${script_dir}/../common/common.sh"
feishu_common_sh="${script_dir}/../feishu-notify/common.sh"
if [[ -f "$feishu_common_sh" ]]; then
    # shellcheck disable=SC1090
    source "$feishu_common_sh"
fi

init_log_file "monitor.log"

config_file="${script_dir}/monitor-modules.conf"
env_file="${script_dir}/.env"
deploy_root="/opt/deploy"
temp_dir="/tmp"
dingtalk_script="${script_dir}/../dingtalk-notify/dingtalk_reminder.py"
dingtalk_scene="monitor_service"
dingtalk_force_at="True"
feishu_scene="monitor_service"
overall_status=0
notify_type="日志监控"

if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$env_file"
    set +a
fi

# True: read *_RECEIVER from .env and @userIds; False: no @
dingtalk_need_at="${DINGTALK_NEED_AT:-False}"
notify_from="${NOTIFY_FROM:-}"
notify_dingtalk_enabled="${NOTIFY_DINGDING:-False}"
notify_feishu_enabled="${NOTIFY_FEISHU:-False}"

usage() {
    log "Usage: $0"
    log "Read modules from ${config_file}, monitor error logs, and send notifications when needed."
}

if [[ -z "${notify_from}" ]]; then
    notify_from=$(hostname)
fi

notify_owner="${notify_from}"

notify_now() {
    date '+%Y-%m-%d %H:%M'
}

format_recovery_notice() {
    local title=$1
    local occurred_time=$2
    local impact=$3
    local reason=$4
    local result=$5

    cat <<EOF
【恢复通知】${title}

异常时间：${occurred_time}
恢复时间：$(notify_now)
当前状态：已恢复

影响范围：
- ${impact}

原因摘要：
- ${reason}

处理结果：
- ${result}

后续动作：
- 持续观察

负责人：${notify_owner}
EOF
}

format_error_notice() {
    local title=$1
    local level=$2
    local status=$3
    local symptom=$4
    local impact=$5
    local judgment=$6
    local next_step=$7

    cat <<EOF
【异常通知】${title}

发现时间：$(notify_now)
异常等级：${level}
当前状态：${status}

异常现象：
- ${symptom}

影响范围：
- 影响用户：使用 ${title%%/*} 的用户
- 影响功能：${impact}
- 影响环境：${notify_owner}

当前判断：
- ${judgment}

下一步动作：
1. ${next_step}

负责人：
EOF
}

notify_dingtalk() {
    local need_at=$1
    local message=$2

    if [[ ! -f "$dingtalk_script" ]]; then
        log "WARN! dingtalk script is missing: ${dingtalk_script}"
        return 0
    fi

    if ! python3 "$dingtalk_script" "$dingtalk_scene" "$need_at" "$message" >> "$LOGFILE" 2>&1; then
        log "WARN! failed to send dingtalk notification"
    fi
}

notify_feishu() {
    local message=$1

    if ! declare -F send_feishu_message >/dev/null 2>&1; then
        return 0
    fi

    if ! send_feishu_message "$feishu_scene" "$message" >> "$LOGFILE" 2>&1; then
        log "WARN! failed to send feishu notification"
    fi
}

notify_message() {
    local need_at=$1
    local message=$2

    case "${notify_dingtalk_enabled}" in
        True|true)
            notify_dingtalk "$need_at" "$message"
            ;;
    esac

    case "${notify_feishu_enabled}" in
        True|true)
            notify_feishu "$message"
            ;;
    esac
}

notify_alert() {
    local message=$1
    notify_message "$dingtalk_force_at" "$message"
}

notify_info() {
    local message=$1
    notify_message "$dingtalk_need_at" "$message"
}

# Find the current running directory for a module (highest version)
find_current_deploy_dir() {
    local module_name=$1
    local candidate_dirs=()
    local dir

    for dir in "${deploy_root}/${module_name}-"*; do
        if [[ -d "$dir" ]]; then
            candidate_dirs+=("$(basename "$dir")")
        fi
    done

    if [[ ${#candidate_dirs[@]} -eq 0 ]]; then
        return 1
    fi

    select_latest_by_fixed_short_commit "$module_name" "${candidate_dirs[@]}"
}

# Compare error logs and return diff
get_error_diff() {
    local new_log=$1
    local old_log=$2
    local diff_output

    if [[ ! -f "$new_log" ]]; then
        echo ""
        return 0
    fi

    local new_content
    new_content=$(cat "$new_log")

    if [[ -z "$new_content" ]]; then
        echo ""
        return 0
    fi

    if [[ ! -f "$old_log" ]]; then
        # Old log doesn't exist, return all new content
        echo "$new_content"
        return 0
    fi

    local old_content
    old_content=$(cat "$old_log")

    if [[ "$new_content" == "$old_content" ]]; then
        echo ""
        return 0
    fi

    # Find the difference using diff
    diff_output=$(diff "$old_log" "$new_log" 2>/dev/null) || true

    if [[ -z "$diff_output" ]]; then
        echo ""
        return 0
    fi

    # Extract lines starting with '>' which are the new lines
    echo "$diff_output" | grep '^>' | sed 's/^> //'
}

# Count lines in diff
count_diff_lines() {
    local diff_content=$1
    printf '%s\n' "$diff_content" | wc -l
}

if [[ $# -ne 0 ]]; then
    usage
    exit 1
fi

load_modules "$config_file" || {
    usage
    exit 1
}

log "\nbegin monitor [$(date)]"

for module_name in "${MODULES[@]}"; do
    log "\nhandle module [${module_name}]"

    # Find current running deploy directory
    if ! find_current_deploy_dir "$module_name"; then
        log "ERROR! current deploy directory not found in ${deploy_root} for ${module_name}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "未找到当前部署目录：${deploy_root}" \
            "无法读取 ${module_name} 的运行日志" \
            "部署目录缺失或目录命名不符合约定" \
            "检查部署目录结构后重新执行监控")"
        overall_status=1
        continue
    fi

    current_dir_name="$SELECTED_NAME"
    current_version="$SELECTED_VERSION"
    current_commit="$SELECTED_COMMIT"
    current_dir="${deploy_root}/${current_dir_name}"

    log "current deploy directory: ${current_dir_name}"
    log "current version: ${current_version}"
    log "current commit: ${current_commit}"

    # Check error log
    error_log="${current_dir}/logs/error.log"
    temp_error_log="${temp_dir}/${module_name}-error.log"

    log "checking error log: ${error_log}"
    touch "$temp_error_log"

    # Get the diff
    diff_content=$(get_error_diff "$error_log" "$temp_error_log")

    if [[ -z "$diff_content" ]]; then
        log "no new error logs for ${module_name}"
        # Update temp log to current state even if empty
        if [[ -f "$error_log" ]]; then
            cp "$error_log" "$temp_error_log"
        else
            : > "$temp_error_log"
        fi
        continue
    fi

    # Count diff lines
    diff_line_count=$(count_diff_lines "$diff_content")
    log "new error log lines: ${diff_line_count}"

    # Prepare message
    if [[ "$diff_line_count" -le 10 ]]; then
        # Send all diff content
        message="$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "已发现，待排查" \
            "${current_dir_name} 检测到 ${diff_line_count} 行新增错误日志" \
            "${module_name} 运行日志出现新增错误" \
            "应用仍在运行，但日志中已出现新的错误输出" \
            "登录节点排查服务日志和运行状态")
附加日志：
${diff_content}"
        log "sending full diff notification for ${module_name}"
        notify_info "$message"
    else
        # Send only last 10 lines
        last_10_lines=$(tail -n 10 "$error_log")
        message="$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "已发现，待排查" \
            "${current_dir_name} 检测到 ${diff_line_count} 行新增错误日志" \
            "${module_name} 运行日志持续出现新增错误" \
            "错误日志新增较多，本次仅截取最近 10 行" \
            "登录节点获取完整日志并排查服务状态")
附加日志（最近 10 行）：
${last_10_lines}"
        log "sending partial diff notification for ${module_name}"
        notify_info "$message"
    fi

    # Update temp error log to current state
    if [[ -f "$error_log" ]]; then
        cp "$error_log" "$temp_error_log"
    else
        : > "$temp_error_log"
    fi
done

log "\nmonitor done. [$(date)]"
exit "$overall_status"
