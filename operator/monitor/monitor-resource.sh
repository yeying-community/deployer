#!/usr/bin/env bash
# Monitor available memory and CPU usage, then send Feishu notifications.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1; pwd)
# shellcheck disable=SC1091
source "${script_dir}/../common/common.sh"
feishu_common_sh="${script_dir}/../feishu-notify/common.sh"
if [[ -f "$feishu_common_sh" ]]; then
    # shellcheck disable=SC1090
    source "$feishu_common_sh"
fi

init_log_file "monitor-resource.log"

env_file="${script_dir}/.env"
feishu_scene="default_notify"
notify_from=""
memory_available_threshold_mb=1024
cpu_usage_threshold=60

if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
fi

notify_from="${NOTIFY_FROM:-}"
if [[ -z "$notify_from" ]]; then
    notify_from=$(hostname)
fi

configured_memory_threshold="${MEMORY_AVAILABLE_THRESHOLD_MB:-}"
if [[ "$configured_memory_threshold" =~ ^[0-9]+$ ]] && (( 10#$configured_memory_threshold > 0 )); then
    memory_available_threshold_mb=$((10#$configured_memory_threshold))
elif [[ -n "$configured_memory_threshold" ]]; then
    log "MEMORY_AVAILABLE_THRESHOLD_MB is invalid, using default ${memory_available_threshold_mb} MB: ${configured_memory_threshold}"
fi

configured_cpu_threshold="${CPU_USAGE_THRESHOLD:-}"
if [[ "$configured_cpu_threshold" =~ ^[0-9]+$ ]] && (( 10#$configured_cpu_threshold <= 100 )); then
    cpu_usage_threshold=$((10#$configured_cpu_threshold))
elif [[ -n "$configured_cpu_threshold" ]]; then
    log "CPU_USAGE_THRESHOLD is invalid, using default ${cpu_usage_threshold}%: ${configured_cpu_threshold}"
fi

notify_feishu() {
    local message=$1

    if ! declare -F send_feishu_message >/dev/null 2>&1; then
        log "WARN! feishu notify helper is missing, skip notification"
        return 0
    fi

    if ! send_feishu_message "$feishu_scene" "$message" >> "$LOGFILE" 2>&1; then
        log "WARN! failed to send feishu notification: scene=${feishu_scene}"
    fi
}

format_resource_alert() {
    local title=$1
    local symptom=$2
    local judgement=$3
    local action=$4

    cat <<EOF
【异常通知】${title}

发现时间：$(date '+%Y-%m-%d %H:%M')
异常等级：P1
当前状态：已发现，待处理

异常现象：
${symptom}

影响范围：
- 影响环境：${notify_from}
- 影响功能：可能导致服务响应变慢或运行失败

当前判断：
- ${judgement}

下一步动作：
1. 登录 ${notify_from} 检查节点资源使用情况
2. ${action}
EOF
}

format_sar_missing_alert() {
    cat <<EOF
【异常通知】CPU 使用情况监控不可用

发现时间：$(date '+%Y-%m-%d %H:%M')

通知内容：
- 节点：${notify_from}
- 原因：sar 命令不存在，无法监控 CPU 使用情况

建议操作：
1. 登录 ${notify_from} 安装 sysstat（提供 sar 命令）
EOF
}

get_top_processes() {
    local resource=$1 sort_field process_lines

    case "$resource" in
        cpu) sort_field="-%cpu" ;;
        memory) sort_field="-%mem" ;;
        *) printf '进程信息获取失败：未知排序类型\n'; return 0 ;;
    esac

    if ! command -v ps >/dev/null 2>&1; then
        printf '进程信息获取失败：ps 命令不存在\n'
        return 0
    fi

    if ! process_lines=$(LC_ALL=C ps -eo pid,user,pcpu,pmem,args --sort="$sort_field" 2>/dev/null | awk '
        NR > 1 && count < 2 {
            pid = $1
            user = $2
            cpu = $3
            memory = $4
            $1 = $2 = $3 = $4 = ""
            sub(/^[[:space:]]+/, "")
            if ($0 ~ /^(ps|awk)([[:space:]]|$)/) next
            command = substr($0, 1, 180)
            if (length($0) > 180) command = command "..."
            printf "%-8s %-12s %6s %6s %s\n", pid, user, cpu, memory, command
            count++
        }
    '); then
        printf '进程信息获取失败：ps 命令执行失败\n'
        return 0
    fi

    if [[ -z "$process_lines" ]]; then
        printf '进程信息获取失败：未获取到进程记录\n'
        return 0
    fi

    printf 'PID      USER             %%CPU   %%MEM  COMMAND\n%s' "$process_lines"
}

check_memory() {
    local available_kb available_mb top_processes

    if ! available_kb=$(awk '/^MemAvailable:/ { print $2; found = 1; exit } END { if (!found) exit 1 }' /proc/meminfo); then
        log "ERROR! failed to read MemAvailable from /proc/meminfo"
        return 0
    fi
    if ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        log "ERROR! invalid MemAvailable value: ${available_kb}"
        return 0
    fi

    available_mb=$((available_kb / 1024))
    log "available memory: ${available_mb} MB (threshold: ${memory_available_threshold_mb} MB)"
    if (( available_mb >= memory_available_threshold_mb )); then
        log "available memory is above the alert threshold, no notification sent"
        return 0
    fi

    log "available memory is below the alert threshold, sending notification"
    top_processes=$(get_top_processes memory)
    notify_feishu "$(format_resource_alert \
        "主机内存告警" \
        "- 可用内存：${available_mb} MB
- 告警阈值：${memory_available_threshold_mb} MB
- 内存占用最高进程：
${top_processes}" \
        "节点可用内存不足" \
        "检查并释放内存，或扩容节点")"
}

check_cpu() {
    if ! command -v sar >/dev/null 2>&1; then
        log "WARN! sar command is missing, CPU usage cannot be monitored"
        notify_feishu "$(format_sar_missing_alert)"
        return 0
    fi

    local sar_output idle_percent cpu_usage top_processes
    if ! sar_output=$(LC_ALL=C sar -u 1 5 2>&1); then
        log "ERROR! failed to collect CPU usage with sar: ${sar_output}"
        notify_feishu "$(format_resource_alert \
            "CPU 使用情况监控不可用" \
            "- 执行 sar -u 1 5 失败：${sar_output}" \
            "无法获取节点 CPU 使用情况" \
            "检查 sysstat 服务及 sar 命令是否正常")"
        return 0
    fi

    if ! idle_percent=$(printf '%s\n' "$sar_output" | awk '$1 == "Average:" && $2 == "all" { print $NF; found = 1; exit } END { if (!found) exit 1 }'); then
        log "ERROR! failed to parse average CPU idle percentage from sar output: ${sar_output}"
        notify_feishu "$(format_resource_alert \
            "CPU 使用情况监控不可用" \
            "- sar 未返回有效的 5 秒平均 CPU 数据" \
            "无法获取节点 CPU 使用情况" \
            "检查 sysstat 及 sar 输出格式")"
        return 0
    fi
    if ! [[ "$idle_percent" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log "ERROR! invalid CPU idle percentage from sar: ${idle_percent}"
        return 0
    fi

    cpu_usage=$(awk -v idle="$idle_percent" 'BEGIN { printf "%.2f", 100 - idle }')
    log "CPU usage: ${cpu_usage}% (threshold: ${cpu_usage_threshold}%, sampled by sar -u 1 5)"
    if ! awk -v usage="$cpu_usage" -v threshold="$cpu_usage_threshold" 'BEGIN { exit !(usage > threshold) }'; then
        log "CPU usage does not exceed the alert threshold, no notification sent"
        return 0
    fi

    log "CPU usage exceeds the alert threshold, sending notification"
    top_processes=$(get_top_processes cpu)
    notify_feishu "$(format_resource_alert \
        "主机 CPU 使用率告警" \
        "- CPU 使用率（5 秒平均）：${cpu_usage}%
- 告警阈值：${cpu_usage_threshold}%
- CPU 占用最高进程：
${top_processes}" \
        "节点 CPU 使用率过高" \
        "检查 CPU 高占用进程并评估节点负载")"
}

check_memory
check_cpu

exit 0
