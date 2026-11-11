#!/usr/bin/env bash
# Publish opted-in repositories when configured Git pathspecs change on origin/main.

set -eo pipefail
umask 077

script_dir=$(cd "$(dirname "$0")" || exit 1; pwd)
config_file="${AUTO_PACKAGE_CONFIG_FILE:-${script_dir}/auto-package-paths.conf}"
state_dir="${AUTO_PACKAGE_STATE_DIR:-/var/lib/deployer-auto-package}"
code_root="${AUTO_PACKAGE_CODE_ROOT:-/root/code}"
compile_script="${AUTO_PACKAGE_COMPILE_SCRIPT:-${script_dir}/compile_packages.sh}"
package_modules_file="${AUTO_PACKAGE_PACKAGE_MODULES_FILE:-${script_dir}/package-modules.conf}"
lock_file="${AUTO_PACKAGE_LOCK_FILE:-/tmp/operator-auto-package.lock}"
log_file="${AUTO_PACKAGE_LOG_FILE:-/opt/logs/auto-package.log}"
initialize=0
check_only=0
initialize_repository=""

if [[ $# -gt 0 ]]; then
    case "$1" in
        --initialize)
            [[ $# -le 2 ]] || { printf 'Usage: %s [--initialize [REPOSITORY]]\n' "$0" >&2; exit 2; }
            initialize=1
            initialize_repository="${2:-}"
            ;;
        --check)
            [[ $# -eq 1 ]] || { printf 'Usage: %s [--check]\n' "$0" >&2; exit 2; }
            check_only=1
            ;;
        *) printf 'Usage: %s [--check | --initialize [REPOSITORY]]\n' "$0" >&2; exit 2 ;;
    esac
fi
if ! command -v flock >/dev/null 2>&1; then
    printf '%s\n' "ERROR! flock is required to serialize automatic package checks" >&2
    exit 1
fi

mkdir -p "$(dirname "$log_file")" "$state_dir"
touch "$log_file" "$lock_file"
exec 9<>"$lock_file"
if ! flock -n 9; then
    printf '[%s] automatic package check already running; skip this cycle\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    exit 0
fi

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log_file"
}

compile_lock_file="${COMPILE_PACKAGES_LOCK_FILE:-/tmp/operator-compile-packages.lock}"
touch "$compile_lock_file"
exec 10<>"$compile_lock_file"
if ! flock -n 10; then
    log "manual or scheduled package compilation already holds ${compile_lock_file}; skip this cycle without changing checkpoints"
    exit 0
fi
log "acquired shared compile lock: ${compile_lock_file}"

write_source_state() {
    local repository=$1 source_commit=$2 temp_file
    temp_file=$(mktemp "${state_dir}/.${repository}.source.XXXXXX") || return 1
    printf '%s\n' "$source_commit" > "$temp_file" || { rm -f "$temp_file"; return 1; }
    chmod 600 "$temp_file" || { rm -f "$temp_file"; return 1; }
    mv -f "$temp_file" "${state_dir}/${repository}.source"
}

write_pending_state() {
    local repository=$1 tag=$2 source_commit=$3 temp_file
    temp_file=$(mktemp "${state_dir}/.${repository}.pending.XXXXXX") || return 1
    printf '%s\n%s\n' "$tag" "$source_commit" > "$temp_file" || { rm -f "$temp_file"; return 1; }
    chmod 600 "$temp_file" || { rm -f "$temp_file"; return 1; }
    mv -f "$temp_file" "${state_dir}/${repository}.pending"
}

find_tag_for_range() {
    local repository_dir=$1 baseline=$2 remote_commit=$3
    shift 3
    local tag tag_body tagged_source diff_status
    FOUND_TAG=""
    FOUND_SOURCE=""

    while IFS= read -r tag; do
        [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || continue
        tag_body=$(git -C "$repository_dir" for-each-ref --format='%(contents:body)' "refs/tags/${tag}") || continue
        tagged_source=$(printf '%s\n' "$tag_body" | sed -n 's/^Source-Commit: //p' | head -n 1)
        [[ "$tagged_source" =~ ^[0-9a-f]{40}$ ]] || continue
        git -C "$repository_dir" merge-base --is-ancestor "$baseline" "$tagged_source" || continue
        git -C "$repository_dir" merge-base --is-ancestor "$tagged_source" "$remote_commit" || continue
        if git -C "$repository_dir" diff --quiet "$baseline" "$tagged_source" -- "$@"; then
            continue
        else
            diff_status=$?
            [[ "$diff_status" -eq 1 ]] || continue
        fi
        FOUND_TAG="$tag"
        FOUND_SOURCE="$tagged_source"
        return 0
    done < <(git -C "$repository_dir" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-creatordate)
    return 1
}

if [[ ! -f "$config_file" ]]; then
    log "ERROR! auto package allowlist is missing: ${config_file}"
    exit 1
fi
if [[ ! -x "$compile_script" ]]; then
    log "ERROR! compile script is missing or not executable: ${compile_script}"
    exit 1
fi
if [[ ! -f "$package_modules_file" ]]; then
    log "ERROR! package module list is missing: ${package_modules_file}"
    exit 1
fi
repositories=()
pathspec_repositories=()
pathspec_values=()
package_repositories=()
while IFS= read -r package_repository || [[ -n "$package_repository" ]]; do
    package_repository="${package_repository%%#*}"
    package_repository="${package_repository%%[[:space:]]*}"
    [[ -n "$package_repository" ]] && package_repositories+=("$package_repository")
done < "$package_modules_file"
while IFS=$' \t' read -r repository pathspec extra || [[ -n "${repository:-}${pathspec:-}${extra:-}" ]]; do
    [[ -n "${repository:-}" && "$repository" != \#* ]] || continue
    if [[ ! "$repository" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ || -z "${pathspec:-}" || -n "${extra:-}" ]]; then
        log "ERROR! invalid allowlist row; expected REPOSITORY PATHSPEC: ${repository:-} ${pathspec:-} ${extra:-}"
        exit 2
    fi
    case "$pathspec" in
        /*|-*|..|../*|*/..|*/../*|*' '*)
            log "ERROR! unsafe or unsupported pathspec for ${repository}: ${pathspec}"
            exit 2
            ;;
    esac
    package_repository_configured=0
    for package_repository in "${package_repositories[@]}"; do
        [[ "$package_repository" == "$repository" ]] && package_repository_configured=1
    done
    if [[ "$package_repository_configured" -ne 1 ]]; then
        log "ERROR! automatic repository is missing from package-modules.conf: ${repository}"
        exit 2
    fi
    found_repository=0
    for existing_repository in "${repositories[@]}"; do
        [[ "$existing_repository" == "$repository" ]] && found_repository=1
    done
    if [[ "$found_repository" -eq 0 ]]; then
        repositories+=("$repository")
    fi
    pathspec_repositories+=("$repository")
    pathspec_values+=("$pathspec")
done < "$config_file"

if [[ ${#repositories[@]} -eq 0 ]]; then
    log "ERROR! automatic package allowlist is empty: ${config_file}"
    exit 1
fi
if [[ -n "$initialize_repository" ]]; then
    configured_repository=0
    for repository in "${repositories[@]}"; do
        [[ "$repository" == "$initialize_repository" ]] && configured_repository=1
    done
    [[ "$configured_repository" -eq 1 ]] || { log "ERROR! repository is not in allowlist: ${initialize_repository}"; exit 2; }
fi

selected_repositories=()
selected_tags=()
overall_status=0

for repository in "${repositories[@]}"; do
    if [[ "$initialize" -eq 1 && -n "$initialize_repository" && "$repository" != "$initialize_repository" ]]; then
        continue
    fi

    repository_dir="${code_root}/${repository}"
    if [[ ! -d "$repository_dir" ]] || ! git -C "$repository_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "ERROR! configured repository is missing or not a Git worktree: ${repository_dir}"
        overall_status=1
        continue
    fi
    branch=$(git -C "$repository_dir" symbolic-ref --quiet --short HEAD || true)
    if [[ "$branch" != "main" ]]; then
        log "ERROR! refusing automatic package for ${repository}: expected branch main, got ${branch:-detached HEAD}"
        overall_status=1
        continue
    fi
    if [[ -n "$(git -C "$repository_dir" status --porcelain)" ]]; then
        log "ERROR! refusing automatic package for ${repository}: worktree has local changes"
        overall_status=1
        continue
    fi
    if ! git -C "$repository_dir" fetch origin main --tags >> "$log_file" 2>&1; then
        log "ERROR! failed to fetch origin/main for ${repository}"
        overall_status=1
        continue
    fi
    remote_commit=$(git -C "$repository_dir" rev-parse refs/remotes/origin/main 2>/dev/null || true)
    if [[ ! "$remote_commit" =~ ^[0-9a-f]{40}$ ]]; then
        log "ERROR! origin/main is unavailable for ${repository}"
        overall_status=1
        continue
    fi

    if [[ "$initialize" -eq 1 ]]; then
        if [[ -e "${state_dir}/${repository}.source" || -e "${state_dir}/${repository}.pending" ]]; then
            log "ERROR! automatic package state already exists for ${repository}; refusing to reset it"
            overall_status=1
            continue
        fi
        if write_source_state "$repository" "$remote_commit"; then
            log "initialized automatic package checkpoint for ${repository}: ${remote_commit}"
        else
            log "ERROR! failed to initialize automatic package checkpoint for ${repository}"
            overall_status=1
        fi
        continue
    fi

    pending_file="${state_dir}/${repository}.pending"
    if [[ -f "$pending_file" ]]; then
        pending_tag=$(sed -n '1p' "$pending_file")
        pending_source=$(sed -n '2p' "$pending_file")
        if [[ ! "$pending_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ || ! "$pending_source" =~ ^[0-9a-f]{40}$ ]] || \
            ! git -C "$repository_dir" merge-base --is-ancestor "$pending_source" "$remote_commit"; then
            log "ERROR! invalid or unreachable pending release state for ${repository}; inspect ${pending_file}"
            overall_status=1
            continue
        fi
        checkpoint_source=$(cat "${state_dir}/${repository}.source" 2>/dev/null || true)
        if [[ "$checkpoint_source" == "$pending_source" ]]; then
            rm -f "$pending_file"
            log "cleared completed automatic release marker for ${repository}: ${pending_tag}"
            continue
        fi
        selected_repositories+=("$repository")
        selected_tags+=("${repository}:${pending_tag}")
        log "retrying pending automatic release for ${repository}: ${pending_tag} from ${pending_source}"
        continue
    fi

    state_file="${state_dir}/${repository}.source"
    if [[ ! -f "$state_file" ]]; then
        log "WARN! automatic package checkpoint is not initialized for ${repository}; run auto_package.sh --initialize ${repository}"
        continue
    fi
    baseline=$(cat "$state_file")
    if [[ ! "$baseline" =~ ^[0-9a-f]{40}$ ]] || ! git -C "$repository_dir" cat-file -e "${baseline}^{commit}" 2>/dev/null; then
        log "ERROR! invalid automatic package checkpoint for ${repository}: ${state_file}"
        overall_status=1
        continue
    fi
    if ! git -C "$repository_dir" merge-base --is-ancestor "$baseline" "$remote_commit"; then
        log "ERROR! origin/main history no longer contains checkpoint ${baseline} for ${repository}; manual review required"
        overall_status=1
        continue
    fi

    repository_pathspecs=()
    for index in "${!pathspec_repositories[@]}"; do
        [[ "${pathspec_repositories[$index]}" == "$repository" ]] && repository_pathspecs+=("${pathspec_values[$index]}")
    done
    if [[ ${#repository_pathspecs[@]} -eq 0 ]]; then
        log "ERROR! no pathspecs configured for ${repository}"
        overall_status=1
        continue
    fi

    if git -C "$repository_dir" diff --quiet "$baseline" "$remote_commit" -- "${repository_pathspecs[@]}"; then
        if [[ "$check_only" -eq 0 && "$baseline" != "$remote_commit" ]] && ! write_source_state "$repository" "$remote_commit"; then
            log "ERROR! unable to advance no-build checkpoint for ${repository}"
            overall_status=1
            continue
        fi
        log "no configured package inputs changed for ${repository} through ${remote_commit}"
        continue
    else
        diff_status=$?
        if [[ "$diff_status" -ne 1 ]]; then
            log "ERROR! git diff failed while checking configured inputs for ${repository}"
            overall_status=1
            continue
        fi
    fi

    if find_tag_for_range "$repository_dir" "$baseline" "$remote_commit" "${repository_pathspecs[@]}"; then
        if [[ "$check_only" -eq 0 ]]; then
            write_pending_state "$repository" "$FOUND_TAG" "$FOUND_SOURCE" || {
                log "ERROR! unable to persist recovered release tag for ${repository}"
                overall_status=1
                continue
            }
        fi
        selected_tags+=("${repository}:${FOUND_TAG}")
        log "recovered existing release tag for ${repository}: ${FOUND_TAG} from ${FOUND_SOURCE}"
    else
        selected_tags+=("")
        log "configured package inputs changed for ${repository}: ${baseline} -> ${remote_commit}"
    fi
    selected_repositories+=("$repository")
done

if [[ "$initialize" -eq 1 ]]; then
    exit "$overall_status"
fi
if [[ "$overall_status" -ne 0 ]]; then
    log "ERROR! automatic package scan had errors; no build was started"
    exit "$overall_status"
fi
if [[ ${#selected_repositories[@]} -eq 0 ]]; then
    log "no opted-in repositories need a package release"
    exit 0
fi
if [[ "$check_only" -eq 1 ]]; then
    log "check-only: would publish repositories: ${selected_repositories[*]}"
    for index in "${!selected_tags[@]}"; do
        [[ -n "${selected_tags[$index]}" ]] && log "check-only: reuse pending tag ${selected_tags[$index]}"
    done
    exit 0
fi

temporary_modules=$(mktemp "${TMPDIR:-/tmp}/auto-package-modules.XXXXXX")
trap 'rm -f "$temporary_modules"' EXIT
printf '%s\n' "${selected_repositories[@]}" > "$temporary_modules"
compile_args=(--publish --modules-file "$temporary_modules" --success-state-dir "$state_dir")
for tag_override in "${selected_tags[@]}"; do
    [[ -n "$tag_override" ]] && compile_args+=(--tag "$tag_override")
done

log "starting automatic release for: ${selected_repositories[*]}"
set +e
COMPILE_PACKAGES_LOCK_BUSY_EXIT_CODE=75 COMPILE_PACKAGES_LOCK_HELD=1 "$compile_script" "${compile_args[@]}" 2>&1 | tee -a "$log_file"
compile_status=${PIPESTATUS[0]}
set -e
if [[ "$compile_status" -eq 75 ]]; then
    log "automatic release deferred because a manual compile task holds the release lock"
    exit 0
fi
if [[ "$compile_status" -ne 0 ]]; then
    log "ERROR! automatic release failed with exit code ${compile_status}; successful repositories retain their own checkpoints, failed tags remain pending"
    exit "$compile_status"
fi
log "automatic release completed for: ${selected_repositories[*]}"
