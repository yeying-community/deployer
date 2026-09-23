#!/usr/bin/env bash
# Monitor root filesystem usage and send Feishu notifications when needed.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1; pwd)
# shellcheck disable=SC1091
source "${script_dir}/../common/common.sh"
feishu_common_sh="${script_dir}/../feishu-notify/common.sh"
if [[ -f "$feishu_common_sh" ]]; then
    # shellcheck disable=SC1090
    source "$feishu_common_sh"
fi

init_log_file "monitor-host.log"

env_file="${script_dir}/.env"
feishu_scene="monitor_service"
notify_from=""
notify_feishu_enabled="False"
disk_usage_threshold="${DISK_USAGE_THRESHOLD:-80}"

if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
fi

notify_from="${NOTIFY_FROM:-}"
notify_feishu_enabled="${NOTIFY_FEISHU:-False}"
disk_usage_threshold="${DISK_USAGE_THRESHOLD:-80}"

if ! [[ "$disk_usage_threshold" =~ ^[0-9]+$ ]]; then
    log "ERROR! DISK_USAGE_THRESHOLD must be an integer between 0 and 100: ${disk_usage_threshold}"
    exit 1
fi

disk_usage_threshold_value=$((10#$disk_usage_threshold))
if (( disk_usage_threshold_value > 100 )); then
    log "ERROR! DISK_USAGE_THRESHOLD must be an integer between 0 and 100: ${disk_usage_threshold}"
    exit 1
fi

if [[ -z "$notify_from" ]]; then
    notify_from=$(hostname)
fi

notify_feishu() {
    local message=$1

    if ! declare -F send_feishu_message >/dev/null 2>&1; then
        log "WARN! feishu notify helper is missing, skip notification"
        return 0
    fi

    if ! send_feishu_message "$feishu_scene" "$message" >> "$LOGFILE" 2>&1; then
        log "WARN! failed to send feishu notification"
    fi
}

format_disk_alert() {
    local filesystem=$1
    local size=$2
    local used=$3
    local available=$4
    local usage=$5

    cat <<EOF
【异常通知】主机磁盘空间告警

发现时间：$(date '+%Y-%m-%d %H:%M')
异常等级：P1
当前状态：已发现，待处理

异常现象：
- 根分区（/）使用率：${usage}%
- 告警阈值：${disk_usage_threshold_value}%
- 文件系统：${filesystem}
- 总容量：${size}
- 已用空间：${used}
- 可用空间：${available}

影响范围：
- 影响环境：${notify_from}
- 影响功能：可能导致日志写入、服务部署及业务运行失败

当前判断：
- 本地系统盘空间不足

下一步动作：
1. 登录 ${notify_from} 检查大文件和日志占用
2. 清理无用文件或扩容系统盘
EOF
}

if ! df_output=$(df -hP / 2>&1); then
    log "ERROR! failed to query root filesystem usage: ${df_output}"
    exit 1
fi

root_line=$(printf '%s\n' "$df_output" | awk 'NR == 2 { print; exit }')
if [[ -z "$root_line" ]]; then
    log "ERROR! failed to parse root filesystem usage: ${df_output}"
    exit 1
fi

read -r root_filesystem root_size root_used root_available root_capacity root_mount <<< "$root_line"
root_usage="${root_capacity%\%}"

if ! [[ "$root_usage" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid root filesystem usage from df: ${root_line}"
    exit 1
fi

log "root filesystem usage: ${root_usage}% (threshold: ${disk_usage_threshold_value}%, filesystem: ${root_filesystem}, mount: ${root_mount})"

if (( root_usage <= disk_usage_threshold_value )); then
    log "root filesystem usage is below the alert threshold, no notification sent"
    exit 0
fi

log "root filesystem usage exceeds the alert threshold, sending notification"
message=$(format_disk_alert "$root_filesystem" "$root_size" "$root_used" "$root_available" "$root_usage")

case "$notify_feishu_enabled" in
    True|true)
        notify_feishu "$message"
        ;;
    *)
        log "feishu notification is disabled, skip notification"
        ;;
esac

exit 0
