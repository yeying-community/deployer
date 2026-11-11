#!/usr/bin/env bash
# build and upload approved release artifacts; no-argument invocations are disabled

if [[ $# -eq 0 ]]; then
    printf '%s\n' "automatic package build is disabled; pass --publish for an approved release"
    exit 0
fi
release_bump="patch"
publish_requested=0
release_unit_versions=()
release_tags=()
modules_file_override=""
success_state_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish) publish_requested=1; shift ;;
        --bump)
            [[ $# -ge 2 ]] || { printf '%s\n' "--bump requires patch, minor, or major" >&2; exit 2; }
            release_bump="$2"; shift 2 ;;
        --unit-version)
            [[ $# -ge 2 ]] || { printf '%s\n' "--unit-version requires REPOSITORY:UNIT=VERSION" >&2; exit 2; }
            [[ "$2" =~ ^[a-z0-9]+(-[a-z0-9]+)*:[a-z0-9]+(-[a-z0-9]+)*=(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { printf 'Invalid --unit-version value: %s\n' "$2" >&2; exit 2; }
            release_unit_versions+=("$2"); shift 2 ;;
        --tag)
            [[ $# -ge 2 ]] || { printf '%s\n' "--tag requires REPOSITORY:vMAJOR.MINOR.PATCH" >&2; exit 2; }
            [[ "$2" =~ ^[a-z0-9]+(-[a-z0-9]+)*:v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { printf 'Invalid --tag value: %s\n' "$2" >&2; exit 2; }
            release_tags+=("$2"); shift 2 ;;
        --modules-file)
            [[ $# -ge 2 ]] || { printf '%s\n' "--modules-file requires a repository list file" >&2; exit 2; }
            modules_file_override="$2"; shift 2 ;;
        --success-state-dir)
            [[ $# -ge 2 ]] || { printf '%s\n' "--success-state-dir requires a state directory" >&2; exit 2; }
            success_state_dir="$2"; shift 2 ;;
        --help|-h)
            printf 'Usage: %s --publish [--bump patch|minor|major] [--tag REPOSITORY:vVERSION] [--unit-version REPOSITORY:UNIT=VERSION ...] [--modules-file FILE] [--success-state-dir DIR]\n' "$0"; exit 0 ;;
    *) printf 'Unknown option: %s\nUsage: %s --publish [--bump patch|minor|major] [--tag REPOSITORY:vVERSION] [--unit-version REPOSITORY:UNIT=VERSION ...] [--modules-file FILE] [--success-state-dir DIR]\n' "$1" "$0" >&2; exit 2 ;;
    esac
done
[[ "$publish_requested" -eq 1 ]] || { printf '%s\n' 'Usage: compile_packages.sh --publish [--bump patch|minor|major] [--tag REPOSITORY:vVERSION] [--unit-version REPOSITORY:UNIT=VERSION ...] [--modules-file FILE] [--success-state-dir DIR]' >&2; exit 2; }
[[ "$release_bump" == patch || "$release_bump" == minor || "$release_bump" == major ]] || { printf 'Invalid bump type: %s (expected patch, minor, or major)\n' "$release_bump" >&2; exit 2; }

set -euo pipefail
shopt -s nullglob

load_host_profile() {
    local profile_file=${1:-/etc/profile}
    [[ -f "$profile_file" ]] || return 0

    # Login profiles may reference optional system variables (for example
    # XDG_DATA_DIRS) that are absent in systemd or other non-login contexts.
    # Load their PATH and tool setup without letting nounset abort the release.
    set +u
    # shellcheck disable=SC1090
    source "$profile_file" >/dev/null 2>&1 || true
    set -euo pipefail
}

# Load host-managed environment only for an explicit release run.
load_host_profile /etc/profile

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

if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "ERROR! jq is required for package API and release manifest validation" >&2
    exit 1
fi

init_log_file "check-code-status.log"

lock_file="${COMPILE_PACKAGES_LOCK_FILE:-/tmp/operator-compile-packages.lock}"
lock_notice_file="${COMPILE_PACKAGES_LOCK_NOTICE_FILE:-${lock_file}.notice}"
lock_notice_interval="${COMPILE_PACKAGES_LOCK_NOTICE_INTERVAL_SECONDS:-300}"
package_config_file="${modules_file_override:-${script_dir}/package-modules.conf}"
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
active_build_repo=""
active_build_workspace=""

cleanup_active_build() {
    if [[ -n "$active_build_repo" && -n "$active_build_workspace" ]]; then
        git -C "$active_build_repo" worktree remove --force "${active_build_workspace}/source" >> "${LOGFILE:-/dev/null}" 2>&1 || true
        rm -rf -- "$active_build_workspace"
    fi
    active_build_repo=""
    active_build_workspace=""
}

trap cleanup_active_build EXIT

acquire_compile_lock() {
    if [[ "${COMPILE_PACKAGES_LOCK_HELD:-0}" == "1" ]]; then
        log "compile packages release lock held by automatic package runner: ${lock_file}"
        return 0
    fi
    touch "$lock_file"
    exec 200<>"$lock_file"
    if ! flock -n 200; then
        local now last_notice holder busy_exit_code

        busy_exit_code="${COMPILE_PACKAGES_LOCK_BUSY_EXIT_CODE:-0}"
        [[ "$busy_exit_code" =~ ^[0-9]+$ ]] && (( busy_exit_code <= 255 )) || busy_exit_code=2

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

        exit "$busy_exit_code"
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
export WEBDAV_PACKAGE_ENV_FILE="$env_file"

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
    log "Usage: $0 --publish [--bump patch|minor|major] [--tag REPOSITORY:vVERSION] [--unit-version REPOSITORY:UNIT=VERSION ...] [--modules-file FILE] [--success-state-dir DIR]"
    log "Without --publish, automatic package build and upload are disabled."
    log "With --publish, read repositories from ${package_config_file}, then build, validate, and upload their artifacts."
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

validate_file_verify_config || exit 1

load_modules "$package_config_file" || {
    usage
    exit 1
}
for unit_override in "${release_unit_versions[@]}"; do
    override_repo="${unit_override%%:*}"
    configured=0
    for configured_module in "${MODULES[@]}"; do
        [[ "$configured_module" == "$override_repo" ]] && configured=1
    done
    [[ "$configured" -eq 1 ]] || { log "ERROR! --unit-version repository is not listed in package-modules.conf: ${override_repo}"; exit 2; }
done
for tag_override in "${release_tags[@]}"; do
    override_repo="${tag_override%%:*}"
    configured=0
    for configured_module in "${MODULES[@]}"; do
        [[ "$configured_module" == "$override_repo" ]] && configured=1
    done
    [[ "$configured" -eq 1 ]] || { log "ERROR! --tag repository is not listed in package-modules.conf: ${override_repo}"; exit 2; }
done

recover_tag_only_commit() {
    local module_name=$1 module_dir=$2 current_commit=$3 remote_commit=$4
    local candidate_tag release_tag="" release_parent allowed_paths version_file changed_path release_changes_safe=1

    while IFS= read -r candidate_tag; do
        [[ "$candidate_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || continue
        if [[ "$(git -C "$module_dir" rev-parse "${candidate_tag}^{commit}" 2>/dev/null || true)" == "$current_commit" ]]; then
            release_tag="$candidate_tag"
            break
        fi
    done < <(git -C "$module_dir" tag --list 'v[0-9]*.[0-9]*.[0-9]*')
    release_parent=$(git -C "$module_dir" rev-parse "${current_commit}^" 2>/dev/null || true)
    [[ -n "$release_tag" && -n "$release_parent" ]] || return 1
    git -C "$module_dir" merge-base --is-ancestor "$release_parent" "$remote_commit" || return 1

    allowed_paths=" scripts/artifact-versions.conf "
    if [[ -f "${module_dir}/scripts/version-files.conf" ]]; then
        while IFS= read -r version_file || [[ -n "$version_file" ]]; do
            [[ -z "$version_file" || "$version_file" == \#* ]] && continue
            allowed_paths+=" ${version_file} "
        done < "${module_dir}/scripts/version-files.conf"
    fi
    while IFS= read -r changed_path; do
        case "$allowed_paths" in
            *" ${changed_path} "*) ;;
            *) release_changes_safe=0; break ;;
        esac
    done < <(git -C "$module_dir" diff-tree --no-commit-id --name-only -r "$current_commit")
    [[ "$release_changes_safe" -eq 1 ]] || return 1

    log "recover ${module_name}: local main is a tagged version-only commit (${release_tag}) based on origin/main history; restore clean main to origin/main while preserving the tag"
    git -C "$module_dir" reset --keep refs/remotes/origin/main >> "$LOGFILE" 2>&1 || return 1
    return 0
}

sync_main_latest() {
    local module_name=$1
    local module_dir=$2
    local current_branch current_commit remote_commit

    if [[ -n "$(git -C "$module_dir" status --porcelain)" ]]; then
        log "ERROR! refusing to build ${module_name}: worktree has local changes"
        return 1
    fi

    current_branch=$(git -C "$module_dir" symbolic-ref --quiet --short HEAD || true)
    if [[ "$current_branch" != "main" ]]; then
        log "ERROR! refusing to build ${module_name}: expected main, got ${current_branch:-detached HEAD}"
        return 1
    fi

    if ! git -C "$module_dir" fetch origin main --tags >> "$LOGFILE" 2>&1; then
        log "ERROR! git fetch origin main failed for ${module_name}"
        return 1
    fi

    log "sync ${module_name}: fast-forward main to origin/main when needed"
    if ! git -C "$module_dir" merge --ff-only refs/remotes/origin/main >> "$LOGFILE" 2>&1; then
        current_commit=$(git -C "$module_dir" rev-parse HEAD)
        remote_commit=$(git -C "$module_dir" rev-parse refs/remotes/origin/main)
        if ! recover_tag_only_commit "$module_name" "$module_dir" "$current_commit" "$remote_commit"; then
            log "ERROR! refusing to build ${module_name}: main cannot fast-forward to origin/main; inspect local commits and branch history"
            return 1
        fi
    fi
    log "sync ${module_name}: main is aligned with origin/main"

    current_commit=$(git -C "$module_dir" rev-parse HEAD) || return 1
    remote_commit=$(git -C "$module_dir" rev-parse refs/remotes/origin/main) || return 1
    if [[ "$current_commit" != "$remote_commit" ]]; then
        if ! recover_tag_only_commit "$module_name" "$module_dir" "$current_commit" "$remote_commit"; then
            log "ERROR! refusing to build ${module_name}: main does not match origin/main after fast-forward"
            return 1
        fi
        current_commit=$(git -C "$module_dir" rev-parse HEAD) || return 1
        [[ "$current_commit" == "$remote_commit" ]] || return 1
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

release_manifest_filename() {
    local repository=$1 version=$2 source_commit=$3
    printf 'release-manifest-%s-v%s-%s.json' "$repository" "$version" "${source_commit:0:7}"
}

write_auto_pending_tag() {
    local state_dir=$1 repository=$2 tag=$3 source_commit=$4 temp_file attempts=0 current_tag="" current_source=""
    [[ "$repository" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
    [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    mkdir -p "$state_dir" || return 1
    if [[ -f "${state_dir}/${repository}.pending" ]]; then
        current_tag=$(sed -n '1p' "${state_dir}/${repository}.pending")
        current_source=$(sed -n '2p' "${state_dir}/${repository}.pending")
        if [[ "$current_tag" == "$tag" && "$current_source" == "$source_commit" ]]; then
            attempts=$(sed -n '3p' "${state_dir}/${repository}.pending")
            [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
        fi
    fi
    attempts=$((attempts + 1))
    temp_file=$(mktemp "${state_dir}/.${repository}.pending.XXXXXX") || return 1
    printf '%s\n%s\n%s\n' "$tag" "$source_commit" "$attempts" > "$temp_file" || { rm -f "$temp_file"; return 1; }
    chmod 600 "$temp_file" || { rm -f "$temp_file"; return 1; }
    mv -f "$temp_file" "${state_dir}/${repository}.pending"
}

write_auto_success_state() {
    local state_dir=$1 repository=$2 source_commit=$3 temp_file pending_source=""
    [[ "$repository" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    mkdir -p "$state_dir" || return 1
    temp_file=$(mktemp "${state_dir}/.${repository}.source.XXXXXX") || return 1
    printf '%s\n' "$source_commit" > "$temp_file" || { rm -f "$temp_file"; return 1; }
    chmod 600 "$temp_file" || { rm -f "$temp_file"; return 1; }
    mv -f "$temp_file" "${state_dir}/${repository}.source" || return 1
    if [[ -f "${state_dir}/${repository}.pending" ]]; then
        pending_source=$(sed -n '2p' "${state_dir}/${repository}.pending")
        if [[ "$pending_source" == "$source_commit" ]]; then
            rm -f "${state_dir}/${repository}.pending" || return 1
        fi
    fi
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
    cleanup_active_build
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

    if [[ ! -f "$package_script" ]]; then
        log "ERROR! package script is missing: ${package_script}"
        overall_status=1
        continue
    fi

    package_api_file="${module_dir}/scripts/package-api.json"
    if [[ ! -f "$package_api_file" ]] || ! jq -e '
        type == "object" and
        .api_version == 1 and
        (.supports | type == "array" and all(.[]; type == "string") and
            (["--ref", "--source-commit", "--version", "--output-dir"] - . == [])) and
        .creates_git_tags == false and
        .pushes_git_refs == false and
        .builds_in_isolated_checkout == true and
        .manifest == "release-manifest.json"
    ' "$package_api_file" >/dev/null 2>&1; then
        log "ERROR! package script has not declared the safe release API: ${package_api_file}"
        overall_status=1
        continue
    fi

    selected_tag=""
    for tag_override in "${release_tags[@]}"; do
        [[ "${tag_override%%:*}" == "$module_name" ]] && selected_tag="${tag_override#*:}"
    done
    if [[ -n "$selected_tag" ]]; then
        if ! git -C "$module_dir" fetch origin "refs/tags/${selected_tag}:refs/tags/${selected_tag}" >> "$LOGFILE" 2>&1; then
            log "ERROR! requested release tag does not exist on origin: ${selected_tag}"
            overall_status=1
            continue
        fi
        latest_tag="$selected_tag"
        latest_commit=$(git -C "$module_dir" rev-parse "${selected_tag}^{commit}")
        source_commit=$(git -C "$module_dir" for-each-ref --format='%(contents:body)' "refs/tags/${selected_tag}" | sed -n 's/^Source-Commit: //p' | head -n 1)
        if [[ -z "$source_commit" ]]; then
            # Legacy release tags point to a version-only commit whose parent is main.
            source_commit=$(git -C "$module_dir" rev-parse "${latest_commit}^" 2>/dev/null || true)
        fi
        build_reason="rebuild existing tag ${selected_tag}"
    else
        tag_args=(--bump "$release_bump")
        for unit_override in "${release_unit_versions[@]}"; do
            override_repo="${unit_override%%:*}"
            override_spec="${unit_override#*:}"
            if [[ "$override_repo" == "$module_name" ]]; then tag_args+=(--unit-version "$override_spec"); fi
        done
        log "create release tag for ${module_name} using ${release_bump} bump"
        if ! tag_output=$(cd "$module_dir" && bash scripts/tag.sh "${tag_args[@]}" 2>&1); then
            printf '%s\n' "$tag_output" >> "$LOGFILE"
            log "ERROR! release tag creation failed for ${module_name}"
            overall_status=1
            continue
        fi
        printf '%s\n' "$tag_output" >> "$LOGFILE"
        latest_tag=$(printf '%s\n' "$tag_output" | sed -n 's/^TAG=\([^ ]*\).*/\1/p' | tail -n 1)
        source_commit=$(printf '%s\n' "$tag_output" | sed -n 's/.*SOURCE_COMMIT=\([^ ]*\).*/\1/p' | tail -n 1)
        if ! git -C "$module_dir" fetch origin "refs/tags/${latest_tag}:refs/tags/${latest_tag}" >> "$LOGFILE" 2>&1; then
            log "ERROR! failed to fetch newly-created release tag ${latest_tag} for ${module_name}"
            overall_status=1
            continue
        fi
        latest_commit=$(git -C "$module_dir" rev-parse "${latest_tag}^{commit}")
        build_reason="tag ${latest_tag} from main ${source_commit:0:7}"
    fi
    if [[ -z "$source_commit" ]] || ! git -C "$module_dir" merge-base --is-ancestor "$source_commit" "$latest_commit" || ! git -C "$module_dir" merge-base --is-ancestor "$source_commit" refs/remotes/origin/main; then
        log "ERROR! release tag ${latest_tag} is not based on a commit in origin/main"
        overall_status=1
        continue
    fi
    if [[ ! "$latest_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        log "ERROR! selected release tag is invalid for ${module_name}: ${latest_tag:-none}"
        overall_status=1
        continue
    fi
    release_version="${latest_tag#v}"

    if [[ -n "$success_state_dir" ]] && ! write_auto_pending_tag "$success_state_dir" "$module_name" "$latest_tag" "$source_commit"; then
        log "ERROR! unable to persist pending automatic release state for ${module_name} ${latest_tag}"
        overall_status=1
        continue
    fi

    active_build_repo="$module_dir"
    active_build_workspace=$(mktemp -d "${TMPDIR:-/tmp}/compile-packages-${module_name}.XXXXXX")
    build_checkout="${active_build_workspace}/source"
    build_output="${active_build_workspace}/output"
    mkdir -p "$build_output"
    if ! git -C "$module_dir" worktree add --detach "$build_checkout" "$latest_commit" >> "$LOGFILE" 2>&1; then
        log "ERROR! failed to create isolated build checkout for ${module_name}"
        overall_status=1
        continue
    fi

    log "build package for ${module_name}: ${build_reason}"
    package_log="$(mktemp)"
    if ! (cd "$build_checkout" && bash scripts/package.sh \
        --ref "$latest_commit" --source-commit "$source_commit" --version "$release_version" --output-dir "$build_output" \
        200>&- > "$package_log" 2>&1); then
        log "ERROR! package script failed for ${module_name}; output:"
        sed -n '1,160p' "$package_log" | tee -a "$LOGFILE"
        if [[ "$(wc -l < "$package_log")" -gt 160 ]]; then
            log "ERROR! package script output truncated; full output: ${package_log}"
        else
            rm -f "$package_log"
        fi
        notify_build_failure \
            "$module_name" \
            "执行构建脚本失败：scripts/package.sh" \
            "构建流程已启动，但脚本执行返回非零状态" \
            "检查模块构建日志并修复后重新打包"
        overall_status=1
        continue
    fi
    cat "$package_log" >> "$LOGFILE"
    rm -f "$package_log"

    manifest_file="${build_output}/release-manifest.json"
    manifest_validator="${script_dir}/package_manifest.sh"
    if [[ ! -f "$manifest_file" ]]; then
        log "ERROR! release manifest is missing: ${manifest_file}"
        notify_build_failure \
            "$module_name" \
            "构建完成后未找到制品清单：${manifest_file}" \
            "项目 package.sh 尚未迁移到 release-manifest.json 契约" \
            "按 specification/PACKAGING.md 生成清单后重新发布"
        overall_status=1
        continue
    fi

    if ! "$manifest_validator" "$manifest_file" \
        --repository "$module_name" --source-commit "$source_commit" >> "$LOGFILE" 2>&1; then
        log "ERROR! invalid release manifest for ${module_name}: ${manifest_file}"
        notify_build_failure \
            "$module_name" \
            "制品清单或包校验失败：${manifest_file}" \
            "清单、包结构、版本、commit 或 SHA-256 不符合打包规范" \
            "检查 package_manifest.sh 输出并修复后重试"
        overall_status=1
        continue
    fi

    artifact_index="${active_build_workspace}/artifacts.tsv"
    if ! "$manifest_validator" "$manifest_file" --artifacts-tsv > "$artifact_index"; then
        log "ERROR! unable to read validated artifact list for ${module_name}"
        overall_status=1
        continue
    fi

    package_names=()
    configured_artifact_count=0
    while IFS=$'\t' read -r artifact_unit artifact_type package_name; do
        [[ -n "$package_name" ]] || continue
        package_names+=("$package_name")
        configured_artifact_count=$((configured_artifact_count + 1))
    done < "$artifact_index"

    if [[ ${#package_names[@]} -eq 0 ]]; then
        log "ERROR! release manifest contains no artifacts for ${module_name}"
        overall_status=1
        continue
    fi

    if [[ "$configured_artifact_count" -eq 0 ]]; then
        log "ERROR! release manifest contains no publishable artifacts for ${module_name}"
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

    module_publish_status=0
    for package_filename in "${package_names[@]}"; do
        package_file="${build_output}/${package_filename}"
        if [[ ! -f "$package_file" ]]; then
            log "ERROR! built package is missing: ${package_file}"
            overall_status=1
            module_publish_status=1
            continue
        fi

        package_hash_after=$(sha256sum "$package_file" | awk '{print $1}')
        local_package_file="${package_root}/${package_filename}"
        if [[ -e "$local_package_file" ]]; then
            if [[ ! -f "$local_package_file" || -L "$local_package_file" ]]; then
                log "ERROR! refusing to replace a non-regular package path: ${local_package_file}"
                overall_status=1
                module_publish_status=1
                continue
            fi
            package_hash_before=$(sha256sum "$local_package_file" | awk '{print $1}')
            if [[ "$package_hash_before" != "$package_hash_after" ]]; then
                log "ERROR! refusing to overwrite immutable package with different bytes: ${package_filename}"
                overall_status=1
                module_publish_status=1
                continue
            fi
            log "package already exists locally with matching SHA-256: ${package_filename}"
        else
            cp "$package_file" "$local_package_file"
        fi

        log "package ready in ${package_root}: ${package_filename}"

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
            module_publish_status=1
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
                module_publish_status=1
                continue
            fi
        fi
    done

    if [[ "$module_publish_status" -eq 0 ]]; then
        manifest_filename=$(release_manifest_filename "$module_name" "$release_version" "$source_commit")
        manifest_destination="${package_root}/${manifest_filename}"
        if [[ -e "$manifest_destination" ]]; then
            if [[ ! -f "$manifest_destination" || -L "$manifest_destination" ]] || ! cmp -s "$manifest_file" "$manifest_destination"; then
                log "ERROR! refusing to overwrite immutable release manifest: ${manifest_filename}"
                overall_status=1
                continue
            fi
        else
            cp "$manifest_file" "$manifest_destination"
        fi
        if ! upload_with_retry "$manifest_filename" "False"; then
            log "ERROR! failed to upload release manifest for ${module_name}"
            overall_status=1
        elif [[ -n "$success_state_dir" ]]; then
            if write_auto_success_state "$success_state_dir" "$module_name" "$source_commit"; then
                log "automatic release checkpoint updated for ${module_name}: ${source_commit}"
            else
                log "ERROR! unable to update automatic release checkpoint for ${module_name}; pending tag ${latest_tag} is retained for retry"
                overall_status=1
            fi
        fi
    else
        log "ERROR! release manifest not published because one or more artifacts failed: ${module_name}"
    fi
done

log "\ncheck code status done. [$(date)]"
exit "$overall_status"
