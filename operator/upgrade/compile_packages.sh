#!/usr/bin/env bash
# check module code status, build package if needed, then upload with retry

# Load host-managed environment first so cron/systemd executions inherit
# configured tool paths such as Maven from /etc/profile.
if [[ -f /etc/profile ]]; then
    # shellcheck disable=SC1091
    source /etc/profile >/dev/null 2>&1 || true
fi

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

# Keep a deterministic baseline PATH for non-login shells (cron/systemd),
# while preserving profile-provided entries such as Maven and nvm CLIs.
export PATH="/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:${PATH}}"

init_log_file "check-code-status.log"

lock_file="${COMPILE_PACKAGES_LOCK_FILE:-/tmp/operator-compile-packages.lock}"
lock_notice_file="${COMPILE_PACKAGES_LOCK_NOTICE_FILE:-${lock_file}.notice}"
lock_notice_interval="${COMPILE_PACKAGES_LOCK_NOTICE_INTERVAL_SECONDS:-300}"
config_file="${script_dir}/modules.conf"
env_file="${script_dir}/.env"
code_root="/root/code"
package_root="/opt/package"
transfer_script="${script_dir}/transfer_packages.sh"
release_notes_script="${script_dir}/../change-log/release_notes.sh"
dingtalk_script="${script_dir}/../dingtalk-notify/dingtalk_reminder.py"
dingtalk_scene="create_package"
feishu_scene="create_package"
overall_status=0
notify_type="版本生成"

acquire_compile_lock() {
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
            log "WARN! compile packages task is already running, skip this cycle, lock file: ${lock_file}, holder: ${holder:-unknown}"
            touch "$lock_notice_file"
        fi

        exit 0
    fi

    : > "$lock_file"
    printf 'pid=%s user=%s started=%s cwd=%s\n' "$$" "$(id -un 2>/dev/null || echo unknown)" "$(date '+%Y-%m-%d %H:%M:%S')" "$(pwd)" >&200
    rm -f "$lock_notice_file"
    log "acquired lock: ${lock_file}"
}

acquire_compile_lock

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
file_verify="$(trim "${FILE_VERIFY:-}")"

ensure_go_in_path() {
    if command -v go >/dev/null 2>&1; then
        return 0
    fi

    if [[ -x /usr/local/go/bin/go ]]; then
        export PATH="${PATH}:/usr/local/go/bin"
    fi
    if command -v go >/dev/null 2>&1; then
        return 0
    fi

    # Non-login shells (cron/systemd) often miss /etc/profile PATH exports.
    if [[ -f /etc/profile ]]; then
        # shellcheck disable=SC1091
        source /etc/profile >/dev/null 2>&1 || true
    fi
    command -v go >/dev/null 2>&1
}

ensure_release_notes_codex() {
    local candidate

    if [[ -n "${RELEASE_NOTES_CODEX_BIN:-}" ]]; then
        if command -v "$RELEASE_NOTES_CODEX_BIN" >/dev/null 2>&1; then
            return 0
        fi
        if [[ "$RELEASE_NOTES_CODEX_BIN" == */* && -x "$RELEASE_NOTES_CODEX_BIN" ]]; then
            export PATH="$(dirname "$RELEASE_NOTES_CODEX_BIN"):${PATH}"
            return 0
        fi
    fi

    for candidate in \
        "${HOME:-/root}"/.nvm/versions/node/*/bin/codex \
        /root/.nvm/versions/node/*/bin/codex \
        /usr/local/bin/codex \
        /usr/bin/codex; do
        if [[ -x "$candidate" ]]; then
            export RELEASE_NOTES_CODEX_BIN="$candidate"
            export PATH="$(dirname "$candidate"):${PATH}"
            return 0
        fi
    done

    if [[ -f /etc/profile ]]; then
        # shellcheck disable=SC1091
        source /etc/profile >/dev/null 2>&1 || true
    fi

    if command -v codex >/dev/null 2>&1; then
        export RELEASE_NOTES_CODEX_BIN="$(command -v codex)"
        return 0
    fi

    return 1
}

usage() {
    log "Usage: $0"
    log "Read modules from ${config_file}, then check/build/upload packages."
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

    cat <<EOF
【构建完成】${title} ${version}

时间：$(notify_now)
环境：${scope}
内容：${content}
状态：${status}
跟进人：
EOF
}

format_error_notice() {
    local title=$1
    local level=$2
    local status=$3
    local symptom=$4
    local impact=$5
    local action=$6
    local next_step=$7

    cat <<EOF
【系统异常】${title}

发现时间：$(notify_now)
异常等级：${level}
当前状态：${status}

异常现象：
- ${symptom}

影响范围：
- 影响用户：内部发布流程
- 影响功能：${impact}
- 影响环境：制品生成/上传

当前判断：
- ${action}

下一步动作：
1. ${next_step}
2. 检查日志 ${LOGFILE}

负责人：${notify_owner}
EOF
}

upload_with_retry() {
    local filename=$1
    local notify_success=${2:-True}
    local attempt
    local module_name="" version=""

    module_name=${filename%%-v*}
    if [[ -z "$module_name" || "$module_name" == "$filename" ]]; then
        module_name="构建产物"
    fi
    if parse_package_name "$module_name" "$filename"; then
        version="v${PARSED_PACKAGE_VERSION}"
    else
        version="$filename"
    fi

    for attempt in 1 2 3; do
        log "upload attempt ${attempt}/3: ${filename}"
        if bash "$transfer_script" upload "$filename" 200>&- >> "$LOGFILE" 2>&1; then
            log "upload completed: ${filename}"
            if [[ "$notify_success" == "True" ]]; then
                notify_message "$dingtalk_need_at" "$(format_release_notice \
                    "${module_name}/构建产物" \
                    "${version}" \
                    "编译节点" \
                    "已完成产物上传：${filename}" \
                    "已构建，上传完毕")"
            fi
            return 0
        fi
        log "upload failed on attempt ${attempt}/3: ${filename}"
        sleep 2
    done

    return 1
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

generate_package_verify_file() {
    local filename=$1
    local verify_filename="${filename}.${file_verify}"

    (
        cd "$package_root"
        "$file_verify" "$filename" > "$verify_filename"
    )
    log "verify file generated: ${package_root}/${verify_filename}"
}

notify_dingtalk() {
    local need_at=$1
    local message=$2

    if [[ ! -f "$dingtalk_script" ]]; then
        log "WARN! dingtalk script is missing: ${dingtalk_script}"
        return 0
    fi

    if ! python3 "$dingtalk_script" "$dingtalk_scene" "$need_at" "$message" 200>&- >> "$LOGFILE" 2>&1; then
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

    if ! python3 "$feishu_reminder_script" --webhook "$webhook" --secret "$secret" --prefix "$prefix" --message "$message" 200>&- >> "$LOGFILE" 2>&1; then
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

notify_build_failure() {
    local module_name=$1
    local symptom=$2
    local action=$3
    local next_step=$4
    local message

    message="$(format_error_notice \
        "${module_name}/${notify_type}" \
        "P2" \
        "处理中" \
        "${symptom}" \
        "新版本产物未完成构建" \
        "${action}" \
        "${next_step}")"

    case "${notify_dingtalk_enabled}" in
        True|true)
            notify_dingtalk "True" "$message"
            ;;
    esac

    case "${notify_feishu_enabled}" in
        True|true)
            notify_feishu_webhook "$message" "CREATE_PACKAGE_WEBHOOK_URL_FAILURE" "CREATE_PACKAGE_SECRET" "CREATE_PACKAGE_PREFIX"
            ;;
    esac
}

notify_release_notes_failure() {
    local module_name=$1
    local symptom=$2
    local action=$3
    local next_step=$4
    local message

    message="$(format_error_notice \
        "${module_name}/发布通知" \
        "P2" \
        "处理中" \
        "${symptom}" \
        "release notes 未生成或未更新" \
        "${action}" \
        "${next_step}")"

    case "${notify_dingtalk_enabled}" in
        True|true)
            notify_dingtalk "True" "$message"
            ;;
    esac

    case "${notify_feishu_enabled}" in
        True|true)
            notify_feishu_webhook "$message" "RELEASE_NOTES_WEBHOOK_URL_FAILURE" "RELEASE_NOTES_SECRET" "RELEASE_NOTES_PREFIX"
            ;;
    esac
}

notify_upload_failure() {
    local message=$1

    case "${notify_dingtalk_enabled}" in
        True|true)
            notify_dingtalk "True" "$message"
            ;;
    esac

    case "${notify_feishu_enabled}" in
        True|true)
            notify_feishu_webhook "$message" "CREATE_PACKAGE_WEBHOOK_URL_FAILURE" "CREATE_PACKAGE_SECRET" "CREATE_PACKAGE_PREFIX"
            ;;
    esac
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

sync_main_latest() {
    local module_name=$1
    local module_dir=$2

    if ! git -C "$module_dir" fetch origin main >> "$LOGFILE" 2>&1; then
        log "ERROR! git fetch origin main failed for ${module_name}"
        return 1
    fi

    # Force local workspace to match origin/main for build determinism.
    if git -C "$module_dir" show-ref --verify --quiet refs/heads/main; then
        if ! git -C "$module_dir" checkout main >> "$LOGFILE" 2>&1; then
            log "ERROR! git checkout main failed for ${module_name}"
            return 1
        fi
    else
        if ! git -C "$module_dir" checkout -b main --track origin/main >> "$LOGFILE" 2>&1; then
            log "ERROR! create local main from origin/main failed for ${module_name}"
            return 1
        fi
    fi

    if ! git -C "$module_dir" reset --hard origin/main >> "$LOGFILE" 2>&1; then
        log "ERROR! git reset --hard origin/main failed for ${module_name}"
        return 1
    fi

    if ! git -C "$module_dir" clean -fd >> "$LOGFILE" 2>&1; then
        log "ERROR! git clean -fd failed for ${module_name}"
        return 1
    fi

    return 0
}

parse_package_name() {
    local module_name=$1
    local package_name=$2
    local stem prefix version commit

    PARSED_PACKAGE_VERSION=""
    PARSED_PACKAGE_COMMIT=""

    case "$package_name" in
        *.tar.gz)
            stem=${package_name%.tar.gz}
            ;;
        *.zip)
            stem=${package_name%.zip}
            ;;
        *)
            return 1
            ;;
    esac

    if [[ "$stem" != "${module_name}-"* ]]; then
        return 1
    fi

    commit=${stem##*-}
    if [[ "${#commit}" -ne 7 || ! "$commit" =~ ^[0-9A-Za-z]{7}$ ]]; then
        return 1
    fi

    prefix=${stem%-${commit}}
    version=${prefix##*-v}
    if [[ "$version" == "$prefix" || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi

    PARSED_PACKAGE_VERSION="$version"
    PARSED_PACKAGE_COMMIT="$commit"
    return 0
}

select_latest_local_package() {
    local module_name=$1
    shift
    local candidates=("$@")
    local item name version commit
    local max_key="" max_name="" max_version="" max_commit="" max_stem=""
    local version_key=""

    for item in "${candidates[@]}"; do
        name=$(basename "$item")
        if ! parse_package_name "$module_name" "$name"; then
            continue
        fi
        version="$PARSED_PACKAGE_VERSION"
        commit="$PARSED_PACKAGE_COMMIT"

        version_key=$(version_key_from_version "$version") || continue
        if [[ -z "$max_name" || "$version_key" > "$max_key" || ( "$version_key" == "$max_key" && "$name" > "$max_stem" ) ]]; then
            max_key="$version_key"
            max_name="$name"
            max_version="$version"
            max_commit="$commit"
            max_stem="$name"
        fi
    done

    SELECTED_NAME="$max_name"
    SELECTED_VERSION="$max_version"
    SELECTED_COMMIT="$max_commit"
    SELECTED_VERSION_KEY="$max_key"
    [[ -n "$SELECTED_NAME" ]]
}

capture_output_package_state() {
    local module_name=$1
    local module_dir=$2
    local state_file=$3
    local package_path package_name package_hash

    : > "$state_file"
    for package_path in \
        "${module_dir}/output/${module_name}-"*.tar.gz \
        "${module_dir}/output/${module_name}-"*.zip; do
        [[ -f "$package_path" ]] || continue
        package_name=$(basename "$package_path")
        package_hash=$(sha256sum "$package_path" | awk '{print $1}')
        printf '%s %s\n' "$package_name" "$package_hash" >> "$state_file"
    done
}

if [[ ! -f "$transfer_script" ]]; then
    log "ERROR! transfer script is missing: ${transfer_script}"
    exit 1
fi

mkdir -p "$package_root"

log "\nbegin check code status [$(date)]"
log "runtime PATH: ${PATH}"
if ensure_go_in_path; then
    log "go command detected: $(command -v go)"
else
    log "WARN! go command not found in PATH before module checks"
fi
if ensure_release_notes_codex; then
    log "release notes codex detected: ${RELEASE_NOTES_CODEX_BIN}"
else
    log "WARN! release notes codex not found before module checks"
fi

for module_name in "${MODULES[@]}"; do
    log "\nhandle module [${module_name}]"

    module_dir="${code_root}/${module_name}"
    package_script="${module_dir}/scripts/package.sh"

    if [[ ! -d "$module_dir" ]]; then
        log "ERROR! code directory is missing: ${module_dir}"
        overall_status=1
        continue
    fi

    if [[ ! -d "${module_dir}/.git" ]]; then
        log "ERROR! not a git repository: ${module_dir}"
        overall_status=1
        continue
    fi

    if ! sync_main_latest "$module_name" "$module_dir"; then
        overall_status=1
        continue
    fi

    latest_commit=$(git -C "$module_dir" rev-parse --short=7 HEAD)
    need_build=0
    build_reason=""

    local_packages=(
        "${package_root}/${module_name}-"*.tar.gz
        "${package_root}/${module_name}-"*.zip
    )
    if [[ ${#local_packages[@]} -eq 0 ]]; then
        need_build=1
        build_reason="no local package found in ${package_root}"
    else
        local_package_names=()
        for package_path in "${local_packages[@]}"; do
            local_package_names+=("$(basename "$package_path")")
        done

        if select_latest_local_package "$module_name" "${local_package_names[@]}"; then
            log "latest local package: ${SELECTED_NAME}"
            log "latest local package version: ${SELECTED_VERSION}, commit: ${SELECTED_COMMIT}"
            log "latest code commit: ${latest_commit}"

            if [[ "$SELECTED_COMMIT" != "$latest_commit" ]]; then
                need_build=1
                build_reason="latest code commit differs from latest package commit"
            else
                log "no build needed for ${module_name}, package commit matches latest code commit"
            fi
        else
            need_build=1
            build_reason="local package names are invalid"
        fi
    fi

    if [[ "$need_build" -eq 0 ]]; then
        continue
    fi

    if [[ ! -f "$package_script" ]]; then
        log "ERROR! package script is missing: ${package_script}"
        notify_build_failure \
            "$module_name" \
            "构建脚本缺失：${package_script}" \
            "模块仓库缺少 scripts/package.sh，无法启动构建流程" \
            "补齐构建脚本后重新执行打包"
        overall_status=1
        continue
    fi

    build_state_before=$(mktemp)
    capture_output_package_state "$module_name" "$module_dir" "$build_state_before"

    log "build package for ${module_name}: ${build_reason}"
    if ! (cd "$module_dir" && bash scripts/package.sh 200>&- >> "$LOGFILE" 2>&1); then
        log "ERROR! package script failed for ${module_name}"
        rm -f "$build_state_before"
        notify_build_failure \
            "$module_name" \
            "执行构建脚本失败：scripts/package.sh" \
            "构建流程已启动，但脚本执行返回非零状态" \
            "检查模块构建日志并修复后重新打包"
        overall_status=1
        continue
    fi

    output_packages=(
        "${module_dir}/output/${module_name}-"*.tar.gz
        "${module_dir}/output/${module_name}-"*.zip
    )
    if [[ ${#output_packages[@]} -eq 0 ]]; then
        log "ERROR! package file not found: ${module_dir}/output/${module_name}-*.{tar.gz,zip}"
        rm -f "$build_state_before"
        notify_build_failure \
            "$module_name" \
            "构建完成后未找到产物：${module_dir}/output/${module_name}-*.{tar.gz,zip}" \
            "构建脚本执行结束，但未生成符合命名规则的压缩包" \
            "检查 output 目录和产物命名规则后重新打包"
        overall_status=1
        continue
    fi

    output_package_names=()
    for package_path in "${output_packages[@]}"; do
        output_package_names+=("$(basename "$package_path")")
    done

    commit_matched_packages=()
    for package_name in "${output_package_names[@]}"; do
        if ! parse_package_name "$module_name" "$package_name"; then
            continue
        fi
        package_commit="$PARSED_PACKAGE_COMMIT"
        if [[ "$package_commit" == "$latest_commit" ]]; then
            commit_matched_packages+=("$package_name")
        fi
    done

    if [[ ${#commit_matched_packages[@]} -eq 0 ]]; then
        log "ERROR! no output package with latest commit (${latest_commit}) for ${module_name}"
        rm -f "$build_state_before"
        notify_build_failure \
            "$module_name" \
            "构建产物未包含最新提交 ${latest_commit}" \
            "output 目录中的产物 commit 标识与当前代码不一致" \
            "检查版本注入逻辑和产物命名后重新打包"
        overall_status=1
        continue
    fi

    if ! select_latest_local_package "$module_name" "${commit_matched_packages[@]}"; then
        log "ERROR! failed to find valid output package for ${module_name} with commit ${latest_commit}"
        rm -f "$build_state_before"
        notify_build_failure \
            "$module_name" \
            "无法识别最新提交 ${latest_commit} 对应的有效构建产物" \
            "产物已生成，但文件名不符合解析规则或版本信息异常" \
            "检查产物命名格式后重新打包"
        overall_status=1
        continue
    fi

    package_filename="$SELECTED_NAME"
    package_file="${module_dir}/output/${package_filename}"
    if [[ ! -f "$package_file" ]]; then
        log "ERROR! built package is missing: ${package_file}"
        rm -f "$build_state_before"
        notify_build_failure \
            "$module_name" \
            "构建产物缺失：${package_file}" \
            "已选中的产物文件不存在，构建结果不完整" \
            "检查构建脚本清理逻辑和 output 目录后重新打包"
        overall_status=1
        continue
    fi

    if [[ ! -f "$release_notes_script" ]]; then
        log "WARN! release notes script is missing: ${release_notes_script}"
        notify_release_notes_failure \
            "$module_name" \
            "release notes 脚本缺失：${release_notes_script}" \
            "构建产物已生成，但发布通知脚本不存在" \
            "补齐 release notes 脚本后重新生成发布通知"
    elif ! bash "$release_notes_script" --module "$module_name" 200>&- >> "$LOGFILE" 2>&1; then
        log "WARN! release notes script failed for ${module_name}"
        notify_release_notes_failure \
            "$module_name" \
            "release notes 生成失败：${module_name}" \
            "构建产物已生成，但发布通知生成脚本执行失败" \
            "检查 release notes 日志和模块仓库状态后重试生成"
    else
        log "release notes generated for ${module_name}"
    fi

    package_hash_after=$(sha256sum "$package_file" | awk '{print $1}')
    package_hash_before=$(awk -v target="$package_filename" '$1 == target {print $2; exit}' "$build_state_before")
    rm -f "$build_state_before"
    if [[ -n "$package_hash_before" && "$package_hash_before" == "$package_hash_after" ]]; then
        log "package already exists for ${module_name}: ${package_filename} (unchanged, reuse)"
    fi

    cp -f "$package_file" "${package_root}/${package_filename}"
    log "package copied to ${package_root}/${package_filename}"

    if verify_algorithm_enabled; then
        generate_package_verify_file "$package_filename"
    fi

    if ! upload_with_retry "$package_filename"; then
        log "ERROR! upload still failed after 3 retries: ${package_filename}"
        notify_upload_failure "$(format_error_notice \
            "${module_name}/${notify_type}" \
            "P2" \
            "处理中" \
            "产物上传连续 3 次失败：${package_filename}" \
            "新版本产物未能同步到制品仓库" \
            "构建已完成，故障出现在上传阶段" \
            "检查网络、WebDAV 配置和传输脚本后重试上传")"
        overall_status=1
        continue
    fi

    if verify_algorithm_enabled; then
        if ! upload_with_retry "${package_filename}.${file_verify}" "False"; then
            log "ERROR! upload still failed after 3 retries: ${package_filename}.${file_verify}"
            notify_upload_failure "$(format_error_notice \
                "${module_name}/${notify_type}" \
                "P2" \
                "处理中" \
                "校验文件上传连续 3 次失败：${package_filename}.${file_verify}" \
                "新版本产物校验文件未能同步到制品仓库" \
                "构建已完成，故障出现在校验文件上传阶段" \
                "检查网络、WebDAV 配置和传输脚本后重试上传")"
            overall_status=1
            continue
        fi
    fi
done

log "\ncheck code status done. [$(date)]"
exit "$overall_status"
