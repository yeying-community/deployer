#!/usr/bin/env bash
# compare remote and local versions, then download and upgrade modules if needed

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

init_log_file "upgrade.log"

lock_file="${UPGRADE_LOCK_FILE:-/tmp/operator-upgrade.lock}"
lock_notice_file="${UPGRADE_LOCK_NOTICE_FILE:-${lock_file}.notice}"
lock_notice_interval="${UPGRADE_LOCK_NOTICE_INTERVAL_SECONDS:-300}"
config_file="${script_dir}/upgrade-modules.conf"
static_units_config="${script_dir}/static-units.conf"
env_file="${script_dir}/.env"
package_root="/opt/package"
deploy_root="/opt/deploy"
transfer_script="${script_dir}/transfer_packages.sh"
dingtalk_script="${script_dir}/../dingtalk-notify/dingtalk_reminder.py"
dingtalk_scene="upgrade_service"
dingtalk_force_at="True"
feishu_scene="upgrade_service"
overall_status=0
notify_type="版本升级"

acquire_upgrade_lock() {
    touch "$lock_file"
    exec 200<>"$lock_file"
    if ! flock -n 200; then
        local now last_notice holder

        now=$(date +%s)
        last_notice=0
        holder=$(tr '\n' ' ' < "$lock_file" | sed 's/[[:space:]]*$//' || true)
        if [[ -f "$lock_notice_file" ]]; then
            last_notice=$(stat -c "%Y" "$lock_notice_file" 2>/dev/null || echo 0)
        fi

        if [[ "$lock_notice_interval" =~ ^[0-9]+$ ]] && (( now - last_notice >= lock_notice_interval )); then
            log "WARN! upgrade task is already running, skip this cycle, lock file: ${lock_file}, holder: ${holder:-unknown}"
            touch "$lock_notice_file"
        fi

        exit 0
    fi

    : > "$lock_file"
    printf 'pid=%s user=%s started=%s cwd=%s\n' "$$" "$(id -un 2>/dev/null || echo unknown)" "$(date '+%Y-%m-%d %H:%M:%S')" "$(pwd)" >&200
    rm -f "$lock_notice_file"
    log "acquired lock: ${lock_file}"
}

acquire_upgrade_lock

# A service launched during an upgrade inherits the shell's open file
# descriptors unless they are closed explicitly. Keep an EXIT cleanup as a
# safety net so an inherited descriptor cannot retain the upgrade lock after
# this script has finished.
release_upgrade_lock() {
    local exit_status=$?

    flock -u 200 || true
    exec 200>&- || true

    return "$exit_status"
}

trap release_upgrade_lock EXIT

if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$env_file"
    set +a
fi

# True: read *_RECEIVER from .env and @userIds; False: no @
dingtalk_need_at="${DINGTALK_NEED_AT:-False}"
notify_from="${NOTIFY_FROM:-}"
notify_same_version="${NOTIFY_SAME_VERSION:-False}"
notify_dingtalk_enabled="${NOTIFY_DINGDING:-False}"
notify_feishu_enabled="${NOTIFY_FEISHU:-False}"
file_verify="$(trim "${FILE_VERIFY:-}")"

usage() {
    log "Usage: $0"
    log "Read modules from ${config_file}, compare remote/latest and local/current, then upgrade when needed."
}

if [[ -z "${notify_from}" ]]; then
    notify_from=$(hostname)
fi

notify_owner="${notify_from}"

notify_now() {
    date '+%Y-%m-%d %H:%M'
}

format_release_notice() {
    local title=$1
    local version=$2
    local scope=$3
    local content=$4
    local status=$5

    # Keep positional arguments stable for existing callers; release notices now
    # always show the operator identity from NOTIFY_FROM/hostname.
    : "$scope"

    cat <<EOF
【发布完成】${title} ${version}

时间：$(notify_now)
环境：${notify_from}
内容：${content}
状态：${status}
跟进人：
EOF
}

format_upgrade_complete_notice() {
    local title=$1
    local version=$2
    local content=$3

    cat <<EOF
【升级完成】${title} ${version}

时间：$(notify_now)
环境：${notify_owner}
内容：${content}
状态：已升级，待验证确认
跟进人：
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
【系统异常】${title}

发现时间：$(notify_now)
异常等级：${level}
当前状态：${status}

异常现象：
- ${symptom}

影响范围：
- 影响用户：使用 ${title%%/*} 的用户
- 影响功能：${impact}

当前判断：
- ${judgment}

下一步动作：
1. ${next_step}
2. 检查日志 ${LOGFILE}

环境信息：${notify_owner}
跟进人：
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

notify_feishu_webhook() {
    local message=$1
    local webhook_var=$2
    local secret_var=${3:-}
    local prefix_var=${4:-}
    local webhook="" secret="" prefix=""

    if ! declare -F feishu_notify_load_config >/dev/null 2>&1; then
        return 0
    fi

    feishu_notify_load_config
    webhook="${!webhook_var:-}"
    if [[ -n "$secret_var" ]]; then
        secret="${!secret_var:-}"
    fi
    if [[ -n "$prefix_var" ]]; then
        prefix="${!prefix_var:-}"
    fi

    if [[ -z "$webhook" ]]; then
        log "WARN! feishu webhook is missing: ${webhook_var}"
        return 0
    fi

    if ! python3 "$feishu_reminder_script" --webhook "$webhook" --secret "$secret" --prefix "$prefix" --message "$message" >> "$LOGFILE" 2>&1; then
        log "WARN! failed to send feishu notification: ${webhook_var}"
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

notify_info() {
    local message=$1
    notify_message "$dingtalk_need_at" "$message"
}

notify_alert() {
    local message=$1

    case "${notify_dingtalk_enabled}" in
        True|true)
            notify_dingtalk "$dingtalk_force_at" "$message"
            ;;
    esac

    case "${notify_feishu_enabled}" in
        True|true)
            notify_feishu_webhook "$message" "UPGRADE_SERVICE_WEBHOOK_URL_FAILURE" "UPGRADE_SERVICE_SECRET" "UPGRADE_SERVICE_PREFIX"
            ;;
    esac
}

notify_same_version_enabled() {
    case "${notify_same_version}" in
        True|true)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

verify_algorithm_enabled() {
    case "$file_verify" in
        sha256sum|md5sum)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_file_verify_config() {
    case "$file_verify" in
        ""|sha256sum|md5sum)
            return 0
            ;;
        *)
            log "ERROR! unsupported FILE_VERIFY: ${file_verify}, expected empty, sha256sum or md5sum"
            return 1
            ;;
    esac
}

verify_downloaded_package() {
    local filename=$1
    local verify_filename="${filename}.${file_verify}"

    if [[ ! -f "${package_root}/${verify_filename}" ]]; then
        log "ERROR! downloaded verify file is missing: ${package_root}/${verify_filename}"
        return 1
    fi

    (
        cd "$package_root"
        "$file_verify" -c "$verify_filename"
    ) >> "$LOGFILE" 2>&1
}

if [[ $# -ne 0 ]]; then
    usage
    exit 1
fi

validate_file_verify_config || exit 1

load_modules "$config_file" || {
    usage
    exit 1
}

update_active_module_symlink() {
    local module_name=$1
    local target_dir=$2
    local link_path="${deploy_root}/${module_name}"
    local target_name

    target_name=$(basename "$target_dir")
    if [[ -e "$link_path" && ! -L "$link_path" ]]; then
        log "ERROR! active link path exists and is not a symlink: ${link_path}"
        return 1
    fi

    ln -sfn "$target_name" "$link_path"
}

find_current_version_from_deploy_dirs() {
    local module_name=$1
    local candidate_dirs=()
    local dir link_path resolved_path resolved_name

    link_path="${deploy_root}/${module_name}"
    if [[ -L "$link_path" ]]; then
        resolved_path=$(readlink -f "$link_path" 2>/dev/null || true)
        resolved_name=$(basename "${resolved_path:-}")
        if [[ -n "$resolved_name" ]] && artifact_info_from_name "$module_name" "$resolved_name"; then
            SELECTED_NAME="$resolved_name"
            SELECTED_VERSION="$PACKAGE_VERSION"
            SELECTED_COMMIT="$PACKAGE_COMMIT"
            SELECTED_VERSION_KEY="$PACKAGE_VERSION_KEY"
            return 0
        fi
        log "WARN! active symlink target is not a valid deployed package for ${module_name}: ${link_path}"
    fi

    for dir in "${deploy_root}/${module_name}-"*; do
        if [[ -d "$dir" ]] && artifact_info_from_name "$module_name" "$(basename "$dir")"; then
            candidate_dirs+=("$(basename "$dir")")
        fi
    done

    if [[ ${#candidate_dirs[@]} -eq 0 ]]; then
        return 1
    fi

    select_latest_by_fixed_short_commit "$module_name" "${candidate_dirs[@]}"
}

resolve_webdav_dir_url_from_env() {
    local base_url custom_dir

    custom_dir=$(trim "${WEBDAV_DIR_URL:-}")
    if [[ -n "$custom_dir" ]]; then
        WEBDAV_DIR_URL="${custom_dir%/}"
        return 0
    fi

    base_url=$(trim "${WEBDAV_PACKAGE_BASE_URL:-}")

    base_url="${base_url%/}"

    WEBDAV_DIR_URL="$base_url"
}

upgrade_static_units() {
    local line repository unit_id site_id health_base_url extra
    local manifest_name manifest_pattern manifest_file source_commit package_name package_file artifact_json
    local target_version target_root target_health_path target_site_path current_target current_root current_version
    local static_site_root artifact_names=() candidate

    if [[ ! -f "$static_units_config" ]]; then
        log "static deployment skipped: optional config is missing: ${static_units_config}"
        return 0
    fi
    if [[ ! -x "${script_dir}/deploy_static_artifact.sh" ]]; then
        log "ERROR! static deployment handler is missing: ${script_dir}/deploy_static_artifact.sh"
        overall_status=1
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "ERROR! jq is required for manifest-driven static deployment"
        overall_status=1
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ -n "${line//[[:space:]]/}" ]] || continue
        repository="" unit_id="" site_id="" health_base_url="" extra=""
        read -r repository unit_id site_id health_base_url extra <<< "$line"
        if [[ -z "$repository" || -z "$unit_id" || -z "$site_id" || -z "$health_base_url" || -n "$extra" ||
              ! "$repository" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ || ! "$unit_id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ||
              ! "$site_id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ || "$health_base_url" != http://* && "$health_base_url" != https://* ]]; then
            log "ERROR! invalid row in ${static_units_config}: ${line}"
            overall_status=1
            continue
        fi

        manifest_pattern="^release-manifest-${repository}-v([0-9]+\\.[0-9]+\\.[0-9]+)-([0-9a-f]{7})\\.json$"
        local manifest_candidates=()
        for candidate in "${remote_files[@]}"; do
            [[ "$candidate" =~ $manifest_pattern ]] && manifest_candidates+=("$candidate")
        done
        if [[ ${#manifest_candidates[@]} -eq 0 ]]; then
            log "ERROR! no release manifest found for static repository ${repository}"
            overall_status=1
            continue
        fi
        manifest_name="$(printf '%s\n' "${manifest_candidates[@]}" | sort -V | tail -n 1)"
        manifest_file="${package_root}/${manifest_name}"
        if [[ ! -f "$manifest_file" || -L "$manifest_file" ]]; then
            if ! bash "$transfer_script" download "$manifest_name" 200>&- >> "$LOGFILE" 2>&1; then
                log "ERROR! failed to download static release manifest: ${manifest_name}"
                overall_status=1
                continue
            fi
        fi
        if [[ ! -f "$manifest_file" || -L "$manifest_file" ]] || ! jq -e --arg repository "$repository" '.schema_version == 1 and .repository == $repository and (.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and (.artifacts | type == "array")' "$manifest_file" >/dev/null 2>&1; then
            log "ERROR! static release manifest is invalid: ${manifest_name}"
            overall_status=1
            continue
        fi
        source_commit="$(jq -r '.source_commit' "$manifest_file")"
        if [[ ! "$manifest_name" =~ $manifest_pattern ]]; then
            log "ERROR! static manifest filename is invalid: ${manifest_name}"
            overall_status=1
            continue
        fi
        local manifest_short_commit="${BASH_REMATCH[2]}"
        if [[ "${source_commit:0:7}" != "$manifest_short_commit" ]]; then
            log "ERROR! static manifest filename does not match its source commit: ${manifest_name}"
            overall_status=1
            continue
        fi
        if ! jq -e --arg unit "$unit_id" --arg site "$site_id" '[.artifacts[] | select(.unit_id == $unit and .type == "static" and any(.static_targets[]; .site_id == $site and .path == ("/opt/deploy/static/" + $site)))] | length == 1' "$manifest_file" >/dev/null 2>&1; then
            log "ERROR! ${manifest_name} does not contain the configured static unit/site: ${unit_id}/${site_id}"
            overall_status=1
            continue
        fi
        if ! jq -e 'all(.artifacts[]; (.package | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*-v[0-9]+\\.[0-9]+\\.[0-9]+-[0-9a-f]{7}\\.tar\\.gz$")) and (.package_root | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*-v[0-9]+\\.[0-9]+\\.[0-9]+-[0-9a-f]{7}$")))' "$manifest_file" >/dev/null 2>&1; then
            log "ERROR! static manifest contains unsafe package names: ${manifest_name}"
            overall_status=1
            continue
        fi

        artifact_names=()
        mapfile -t artifact_names < <(jq -r '.artifacts[].package' "$manifest_file")
        local artifacts_ready=1
        for package_name in "${artifact_names[@]}"; do
            [[ -n "$package_name" ]] || continue
            if [[ ! -f "${package_root}/${package_name}" || -L "${package_root}/${package_name}" ]]; then
                if [[ ! " ${remote_files[*]} " == *" ${package_name} "* ]] || ! bash "$transfer_script" download "$package_name" 200>&- >> "$LOGFILE" 2>&1; then
                    log "ERROR! failed to download package referenced by ${manifest_name}: ${package_name}"
                    artifacts_ready=0
                    break
                fi
            fi
        done
        if [[ "$artifacts_ready" -ne 1 ]]; then
            overall_status=1
            continue
        fi
        if ! "${script_dir}/package_manifest.sh" "$manifest_file" --repository "$repository" --source-commit "$source_commit" >> "$LOGFILE" 2>&1; then
            log "ERROR! static release manifest or artifact validation failed: ${manifest_name}"
            overall_status=1
            continue
        fi
        artifact_json="$(jq -c --arg unit "$unit_id" --arg site "$site_id" '[.artifacts[] | select(.unit_id == $unit and .type == "static" and any(.static_targets[]; .site_id == $site))][0]' "$manifest_file")"
        package_name="$(jq -r '.package' <<< "$artifact_json")"
        target_version="$(jq -r '.version' <<< "$artifact_json")"
        target_root="$(jq -r '.package_root' <<< "$artifact_json")"
        target_site_path="$(jq -r --arg site "$site_id" '.static_targets[] | select(.site_id == $site) | .path' <<< "$artifact_json")"
        target_health_path="$(jq -r --arg site "$site_id" '.static_targets[] | select(.site_id == $site) | .health_check_path' <<< "$artifact_json")"
        if [[ "$target_site_path" != "/opt/deploy/static/${site_id}" ]] || ! artifact_info_from_name "$unit_id" "$target_root" || [[ "$PACKAGE_VERSION" != "$target_version" ]]; then
            log "ERROR! static artifact identity or destination is invalid for ${unit_id}"
            overall_status=1
            continue
        fi

        static_site_root="${deploy_root}/static/${site_id}"
        current_version=""
        current_root=""
        if [[ -L "${static_site_root}/current" ]]; then
            current_target="$(readlink "${static_site_root}/current")"
            if [[ "$current_target" != releases/* || "$current_target" == *..* ]]; then
                log "ERROR! static current link escapes its release directory: ${static_site_root}/current"
                overall_status=1
                continue
            fi
            current_root="${current_target#releases/}"
            if ! artifact_info_from_name "$unit_id" "$current_root"; then
                log "ERROR! current static package name is invalid for ${unit_id}: ${current_root}"
                overall_status=1
                continue
            fi
            current_version="$PACKAGE_VERSION"
        elif [[ -e "${static_site_root}/current" ]]; then
            log "ERROR! static current path is not a symlink: ${static_site_root}/current"
            overall_status=1
            continue
        fi
        if [[ "$current_root" == "$target_root" ]] || { [[ -n "$current_version" ]] && ! version_gt "$target_version" "$current_version"; }; then
            log "static site ${site_id} is up to date (current=${current_version:-none}, remote=${target_version})"
            continue
        fi

        package_file="${package_root}/${package_name}"
        if ! "${script_dir}/deploy_static_artifact.sh" "$package_file" "$unit_id" "$site_id" "$target_root" "$target_health_path" "$health_base_url" >> "$LOGFILE" 2>&1; then
            log "ERROR! static deployment failed and previous current link was restored when available: ${site_id}"
            overall_status=1
            continue
        fi
        log "static deployment completed: ${site_id} -> ${target_root}"
    done < "$static_units_config"
}

if [[ ! -f "$transfer_script" ]]; then
    log "ERROR! transfer script is missing: ${transfer_script}"
    exit 1
fi

load_webdav_env "$env_file" || exit 1
resolve_webdav_dir_url_from_env
mkdir -p "$package_root" "$deploy_root"
log "webdav remote dir: ${WEBDAV_DIR_URL}/"
if [[ -n "${WEBDAV_PACKAGE_AK:-}" ]]; then
    log "webdav access key: configured"
else
    log "webdav access key: <empty>"
fi

HEALTH_CHECK_INITIAL_WAIT_SECONDS=$(trim "${HEALTH_CHECK_INITIAL_WAIT_SECONDS:-0}")
WAIT_SECONDS=$(trim "${WAIT_SECONDS:-2}")
RETRY_TIMES=$(trim "${RETRY_TIMES:-10}")

if ! [[ "$HEALTH_CHECK_INITIAL_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid HEALTH_CHECK_INITIAL_WAIT_SECONDS: ${HEALTH_CHECK_INITIAL_WAIT_SECONDS}, expected a non-negative integer"
    exit 1
fi

if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid WAIT_SECONDS: ${WAIT_SECONDS}, expected a non-negative integer"
    exit 1
fi

if ! [[ "$RETRY_TIMES" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid RETRY_TIMES: ${RETRY_TIMES}, expected a non-negative integer"
    exit 1
fi

mapfile -t remote_files < <(webdav_list_files) || exit 1
log "remote files count: ${#remote_files[@]}"
log "\nbegin upgrade [$(date)]"

for module_name in "${MODULES[@]}"; do
    log "\nhandle module [${module_name}]"

    remote_candidates=()
    for remote_name in "${remote_files[@]}"; do
        if [[ "$remote_name" == "${module_name}-"*.tar.gz ]]; then
            remote_candidates+=("$remote_name")
        fi
    done

    if [[ ${#remote_candidates[@]} -eq 0 ]]; then
        target_package_names="${module_name}-*.tar.gz"
        remote_base_url_for_notice=$(trim "${WEBDAV_PACKAGE_BASE_URL:-}")
        remote_base_url_for_notice="${remote_base_url_for_notice%/}"
        log "ERROR! no remote package found for ${module_name}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "需要处理" \
            "未在配置的目录中找到目标安装包[${target_package_names}]" \
            "无法为 ${module_name} 执行版本升级" \
            "远程目录[${remote_base_url_for_notice}]缺少缺少该模块的发布包[${target_package_names}]" \
            "检查制品仓库内容并补齐安装包后重新执行升级")"
        if [[ ${#remote_files[@]} -gt 0 ]]; then
            log "remote file samples:"
            printf '%s\n' "${remote_files[@]:0:50}" | tee -a "$LOGFILE" >/dev/null
        fi
        overall_status=1
        continue
    fi

    if ! select_latest_by_fixed_short_commit "$module_name" "${remote_candidates[@]}"; then
        log "ERROR! failed to parse remote package version for ${module_name}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "远程安装包版本解析失败" \
            "无法判断 ${module_name} 的目标升级版本" \
            "远程安装包命名不符合约定格式" \
            "检查远程文件命名规则后重新执行升级")"
        overall_status=1
        continue
    fi

    target_filename="$SELECTED_NAME"
    target_version="$SELECTED_VERSION"
    target_dir_name="${target_filename%.tar.gz}"
    log "target package: ${target_filename}"
    log "target version: ${target_version}"

    current_version=""
    if find_current_version_from_deploy_dirs "$module_name"; then
        current_version="$SELECTED_VERSION"
        current_dir="${deploy_root}/${SELECTED_NAME}"
        log "current version: ${current_version}"
    else
        log "ERROR! current version directory not found in ${deploy_root} for ${module_name}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "本地当前版本目录不存在：${deploy_root}" \
            "无法识别 ${module_name} 当前运行版本" \
            "部署目录缺失或目录命名不符合约定" \
            "检查部署目录结构后重新执行升级")"
        overall_status=1
        continue
    fi

    if ! version_gt "$target_version" "$current_version"; then
        log "no upgrade needed for ${module_name}, current version ${current_version} is up to date"
        if notify_same_version_enabled; then
            notify_info "$(format_release_notice \
                "${module_name}/升级检查" \
                "v${current_version}" \
                "${notify_from}" \
                "远程版本 v${target_version} 与当前版本一致，无需升级" \
                "无需升级，当前版本已是最新")"
        fi
        continue
    fi

    log "upgrade needed for ${module_name}: ${current_version} -> ${target_version}"

    verify_enabled=1
    if verify_algorithm_enabled; then
        verify_enabled=0
        target_verify_filename="${target_filename}.${file_verify}"
        if ! bash "$transfer_script" download "$target_verify_filename" 200>&- >> "$LOGFILE" 2>&1; then
            log "ERROR! failed to download verify file: ${target_verify_filename}"
            notify_alert "$(format_error_notice \
                "${module_name}/${notify_type}" \
                "P2" \
                "处理中" \
                "校验文件下载失败：${target_verify_filename}" \
                "升级流程中断，目标版本无法完成完整性校验" \
                "制品仓库中缺少校验文件或下载流程失败" \
                "检查制品仓库校验文件和下载脚本后重试升级")"
            overall_status=1
            continue
        fi
    fi

    if ! bash "$transfer_script" download "$target_filename" 200>&- >> "$LOGFILE" 2>&1; then
        log "ERROR! failed to download package: ${target_filename}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "安装包下载失败：${target_filename}" \
            "升级流程中断，目标版本无法落盘" \
            "制品仓库访问异常或下载流程失败" \
            "检查网络、凭据和下载脚本后重试升级")"
        overall_status=1
        continue
    fi

    package_file="${package_root}/${target_filename}"
    if [[ ! -f "$package_file" ]]; then
        log "ERROR! downloaded package is missing: ${package_file}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "下载完成后未找到安装包文件：${target_filename}" \
            "升级流程无法继续解压安装包" \
            "下载结果未落到预期目录或文件被清理" \
            "检查制品目录和下载脚本输出后重试升级")"
        overall_status=1
        continue
    fi

    if [[ "$verify_enabled" -eq 0 ]] && ! verify_downloaded_package "$target_filename"; then
        log "ERROR! package verify failed: ${target_filename}"
        rm -f "$package_file"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "软件包校验不通过，等待下一个检测周期或者稍后尝试" \
            "已删除校验失败的软件包，当前模块升级中止" \
            "下载的软件包校验结果与校验文件内容不一致" \
            "等待下一个检测周期或者稍后尝试")"
        overall_status=1
        continue
    fi

    if ! ensure_extracted_dir "$package_file" "$deploy_root" "$target_dir_name"; then
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "安装包解压失败：${target_filename}" \
            "目标版本目录未能完成准备" \
            "安装包内容异常或解压流程失败" \
            "检查安装包完整性和磁盘空间后重新执行升级")"
        overall_status=1
        continue
    fi
    log "package extracted to ${EXTRACTED_DIR}"

    upgrade_script="${EXTRACTED_DIR}/scripts/upgrade.sh"
    if [[ ! -f "$upgrade_script" ]]; then
        log "ERROR! upgrade script is missing: ${upgrade_script}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "缺少项目升级脚本：${upgrade_script}" \
            "无法执行 ${module_name} 的版本切换" \
            "安装包未提供标准 scripts/upgrade.sh" \
            "在项目中补齐 scripts/upgrade.sh 并重新打包")"
        overall_status=1
        continue
    fi

    run_project_upgrade_hook() {
        local phase=$1

        bash "$upgrade_script" "$phase" "$current_dir" "$EXTRACTED_DIR" 200>&- >> "$LOGFILE" 2>&1
    }

    service_upgrade_enabled=1
    if run_project_upgrade_hook prepare; then
        :
    else
        upgrade_script_status=$?
        if [[ "$upgrade_script_status" -eq 10 ]]; then
            service_upgrade_enabled=0
            log "project upgrade script selected custom-only mode for ${module_name}"
        else
            log "ERROR! project upgrade prepare hook failed for ${module_name}"
            notify_alert "$(format_error_notice \
                "${module_name}/${notify_type}" \
                "P1" \
                "处理中" \
                "项目升级脚本 prepare 阶段执行失败" \
                "${module_name} 未完成从 v${current_version} 到 v${target_version} 的升级" \
                "升级前定制步骤失败" \
                "检查项目 scripts/upgrade.sh 日志并重新执行升级")"
            overall_status=1
            continue
        fi
    fi

    if [[ "$service_upgrade_enabled" -eq 1 ]]; then
        [[ -f "${current_dir}/scripts/starter.sh" ]] || {
            log "ERROR! missing script: ${current_dir}/scripts/starter.sh"
            overall_status=1
            continue
        }
        [[ -f "${EXTRACTED_DIR}/scripts/starter.sh" ]] || {
            log "ERROR! missing script: ${EXTRACTED_DIR}/scripts/starter.sh"
            overall_status=1
            continue
        }
        log "stop current ${module_name}: cd ${current_dir} && scripts/starter.sh stop"
        if ! (cd "$current_dir" && bash scripts/starter.sh stop 200>&- >> "$LOGFILE" 2>&1); then
            log "ERROR! failed to stop current ${module_name} service"
            overall_status=1
            continue
        fi

        if run_project_upgrade_hook copy-config; then
            :
        else
            upgrade_script_status=$?
            log "ERROR! project upgrade copy-config hook failed for ${module_name}"
            notify_alert "$(format_error_notice \
                "${module_name}/${notify_type}" \
                "P1" \
                "处理中" \
                "项目升级脚本 copy-config 阶段执行失败" \
                "${module_name} 未完成从 v${current_version} 到 v${target_version} 的升级" \
                "配置迁移失败，退出码 ${upgrade_script_status}" \
                "检查项目 scripts/upgrade.sh 日志并重新执行升级")"
            overall_status=1
            continue
        fi
    fi

    if run_project_upgrade_hook post-copy; then
        :
    else
        upgrade_script_status=$?
        log "ERROR! project upgrade post-copy hook failed for ${module_name}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P1" \
            "处理中" \
            "项目升级脚本 post-copy 阶段执行失败" \
            "${module_name} 未完成从 v${current_version} 到 v${target_version} 的升级" \
            "升级后定制步骤失败，退出码 ${upgrade_script_status}" \
            "检查项目 scripts/upgrade.sh 日志并重新执行升级")"
        overall_status=1
        continue
    fi

    if [[ "$service_upgrade_enabled" -eq 1 ]]; then
        log "start target ${module_name}: cd ${EXTRACTED_DIR} && scripts/starter.sh"
        # Keep stdin attached to the caller so project starters can securely
        # request interactive input (for example, node's secrets password).
        # tee mirrors output to the terminal and the upgrade log, while
        # closing fd 200 prevents the service from inheriting the upgrade lock.
        if (cd "$EXTRACTED_DIR" && bash scripts/starter.sh 200>&-) 2>&1 | tee -a "$LOGFILE"; then
            :
        else
            start_status=$?
            log "ERROR! failed to start target ${module_name} service with exit code ${start_status}"
            overall_status=1
            continue
        fi

        if [[ -f "${EXTRACTED_DIR}/scripts/health-check.sh" ]]; then
            health_check_status=0
            max_health_check_attempts=$((RETRY_TIMES + 1))

            for ((attempt = 1; attempt <= max_health_check_attempts; attempt++)); do
                health_check_wait_seconds="$HEALTH_CHECK_INITIAL_WAIT_SECONDS"
                if (( attempt > 1 )); then
                    health_check_wait_seconds="$WAIT_SECONDS"
                fi
                if (( health_check_wait_seconds > 0 )); then
                    if (( attempt == 1 )); then
                        log "wait ${health_check_wait_seconds}s before initial ${module_name} health check"
                    else
                        log "wait ${health_check_wait_seconds}s before ${module_name} health check retry ${attempt}/${max_health_check_attempts}"
                    fi
                    sleep "$health_check_wait_seconds"
                fi

                log "health check target ${module_name} attempt ${attempt}/${max_health_check_attempts}: cd ${EXTRACTED_DIR} && scripts/health-check.sh --level all"
                if (cd "$EXTRACTED_DIR" && bash scripts/health-check.sh --level all 200>&- >> "$LOGFILE" 2>&1); then
                    health_check_status=0
                    break
                else
                    health_check_status=$?
                fi

                log "${module_name} health check failed on attempt ${attempt}/${max_health_check_attempts} with exit code ${health_check_status}"
            done

            if [[ $health_check_status -ne 0 ]]; then
                log "ERROR! ${module_name} health check failed after ${max_health_check_attempts} attempt(s)"
                overall_status=1
                continue
            fi

            log "${module_name} health check passed"
        else
            log "WARN! skip ${module_name} health check, script is missing: ${EXTRACTED_DIR}/scripts/health-check.sh"
        fi
    fi

    if run_project_upgrade_hook finalize; then
        :
    else
        log "ERROR! project upgrade finalize hook failed for ${module_name}"
        overall_status=1
        continue
    fi

    if ! update_active_module_symlink "$module_name" "$EXTRACTED_DIR"; then
        log "ERROR! failed to update active symlink for ${module_name}"
        notify_alert "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P1" \
            "处理中" \
            "运行目录软链接更新失败：${deploy_root}/${module_name}" \
            "无法稳定定位 ${module_name} 当前运行版本的配置和日志" \
            "部署目录存在同名实体目录或软链接更新失败" \
            "检查 ${deploy_root}/${module_name} 后重新执行升级")"
        overall_status=1
        continue
    fi

    log "upgrade finished for ${module_name}: ${current_version} -> ${target_version}"
    log "active symlink updated: ${deploy_root}/${module_name} -> $(basename "$EXTRACTED_DIR")"

    notify_info "$(format_upgrade_complete_notice \
        "${module_name}/服务升级" \
        "v${target_version}" \
        "已完成版本升级：v${current_version} -> v${target_version}")"

    active_module_dir="${deploy_root}/${module_name}"
    config_backup_script="${active_module_dir}/scripts/config_backup.sh"
    if [[ ! -f "$config_backup_script" ]]; then
        log "无法进行备份和上传操作，配置备份脚本不存在：${config_backup_script}"
    else
        log "config backup： ${module_name}"
        if (cd "$active_module_dir" && bash scripts/config_backup.sh 200>&- >> "$LOGFILE" 2>&1); then
            sleep 5
            log "config backup upload： ${module_name}"
            if ! bash "${script_dir}/../backup-config/upload_config_backup.sh" "${module_name}" 200>&- >> "$LOGFILE" 2>&1; then
                log "ERROR! config backup upload failed: ${module_name}"
            fi
        else
            log "ERROR! config backup failed: ${module_name}"
        fi
    fi
done

upgrade_static_units

log "\nupgrade done. [$(date)]"
exit "$overall_status"
