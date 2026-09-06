#!/usr/bin/env bash
# upgrade node service from one deployed version to another

set -euo pipefail
shopt -s nullglob

script_dir=$(cd "$(dirname "$0")" || exit 1; pwd)
# shellcheck disable=SC1091
source "${script_dir}/../common/common.sh"

init_log_file "upgrade-node.log"

env_file="${script_dir}/.env"

module_name="node"
deploy_root="/opt/deploy"

usage() {
    log "Usage: $0 [current_version] [target_version]"
}

resolve_version_dir() {
    local version=$1
    local candidates=()
    local dir

    for dir in "${deploy_root}/${module_name}-"*; do
        if [[ -d "$dir" ]] && artifact_info_from_name "$module_name" "$(basename "$dir")" && [[ "$PACKAGE_VERSION" == "$version" ]]; then
            candidates+=("$(basename "$dir")")
        fi
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    fi

    select_latest_named_item "$module_name" "${candidates[@]}" || return 1
    printf '%s/%s' "$deploy_root" "$SELECTED_NAME"
}

resolve_secrets_paths() {
    local config_path=$1
    local root_dir=$2

    node - "$config_path" "$root_dir" <<'NODE'
const path = require('path')
const config = require(path.resolve(process.argv[2]))
const secrets = config.secrets || {}
const rootDir = path.resolve(process.argv[3])
process.stdout.write(`${path.resolve(rootDir, secrets.file || 'run/secrets.enc.json')}\n${path.resolve(rootDir, secrets.passwordFile || 'run/.secrets-password')}\n`)
NODE
}

patch_starter_password_file_reuse() {
    local starter_file=$1

    node - "$starter_file" <<'NODE'
const fs = require('fs')
const starterFile = process.argv[2]
const source = fs.readFileSync(starterFile, 'utf8')
const from = `  if [[ -f "$SECRETS_PASSWORD_FILE" ]]; then
    if ! is_production_environment; then
      return 0
    fi
  fi`
const to = `  if [[ -f "$SECRETS_PASSWORD_FILE" ]]; then
    return 0
  fi`

if (source.includes(to)) {
  process.exit(0)
}

if (!source.includes(from)) {
  console.error('starter.sh password-file block was not recognized')
  process.exit(1)
}

fs.writeFileSync(starterFile, source.replace(from, to))
NODE
}

copy_run_dir() {
    local src_dir=$1
    local dst_dir=$2
    local entries=()

    [[ -d "$src_dir" ]] || return 1
    mkdir -p "$dst_dir"

    shopt -s dotglob nullglob
    entries=("$src_dir"/*)
    shopt -u dotglob

    if [[ ${#entries[@]} -eq 0 ]]; then
        return 0
    fi

    cp -a "${entries[@]}" "$dst_dir/"
}

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

current_version=$(trim "$1")
target_version=$(trim "$2")

if [[ -z "$current_version" || -z "$target_version" ]]; then
    usage
    exit 1
fi

if [[ "$current_version" == "$target_version" ]]; then
    log "current_version equals target_version (${current_version}), skip node upgrade."
    exit 0
fi

current_dir=$(resolve_version_dir "$current_version") || {
    log "ERROR! current version directory is missing: /opt/deploy/node-v${current_version}-****"
    exit 1
}
target_dir=$(resolve_version_dir "$target_version") || {
    log "ERROR! target version directory is missing: /opt/deploy/node-v${target_version}-****"
    exit 1
}

log "current dir: ${current_dir}"
log "target dir: ${target_dir}"

if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
fi

WAIT_SECONDS=$(trim "${WAIT_SECONDS:-0}")
RETRY_TIMES=$(trim "${RETRY_TIMES:-0}")

if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid WAIT_SECONDS: ${WAIT_SECONDS}, expected a non-negative integer"
    exit 1
fi

if ! [[ "$RETRY_TIMES" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid RETRY_TIMES: ${RETRY_TIMES}, expected a non-negative integer"
    exit 1
fi

[[ -f "${current_dir}/scripts/starter.sh" ]] || { log "ERROR! missing script: ${current_dir}/scripts/starter.sh"; exit 1; }
[[ -f "${target_dir}/scripts/starter.sh" ]] || { log "ERROR! missing script: ${target_dir}/scripts/starter.sh"; exit 1; }
[[ -f "${current_dir}/config.js" ]] || { log "ERROR! missing config: ${current_dir}/config.js"; exit 1; }
[[ -e "${current_dir}/run" ]] || { log "ERROR! missing run: ${current_dir}/run"; exit 1; }
[[ -d "${target_dir}/run" ]] || mkdir -p "${target_dir}/run"

current_secrets_paths=$(resolve_secrets_paths "${current_dir}/config.js" "$current_dir") || {
    log "ERROR! failed to resolve current node secrets config: ${current_dir}/config.js"
    exit 1
}
current_secrets_file=$(printf '%s\n' "$current_secrets_paths" | sed -n '1p')
current_secrets_password_file=$(printf '%s\n' "$current_secrets_paths" | sed -n '2p')

log "stop current node: cd ${current_dir} && scripts/starter.sh stop"
if ! (cd "$current_dir" && bash scripts/starter.sh stop >> "$LOGFILE" 2>&1); then
    log "ERROR! failed to stop current node service"
    exit 1
fi

cp -f "${current_dir}/config.js" "${target_dir}/config.js"
log "copied config: ${current_dir}/config.js -> ${target_dir}/config.js"

copy_run_dir "${current_dir}/run" "${target_dir}/run" || {
    log "ERROR! failed to copy run directory: ${current_dir}/run -> ${target_dir}/run"
    exit 1
}
log "copied run: ${current_dir}/run -> ${target_dir}/run"

target_secrets_paths=$(resolve_secrets_paths "${target_dir}/config.js" "$target_dir") || {
    log "ERROR! failed to resolve target node secrets config: ${target_dir}/config.js"
    exit 1
}
target_secrets_file=$(printf '%s\n' "$target_secrets_paths" | sed -n '1p')
target_secrets_password_file=$(printf '%s\n' "$target_secrets_paths" | sed -n '2p')

if [[ "$current_secrets_password_file" == "$target_secrets_password_file" ]]; then
    log "skip copying secrets.passwordFile, source and target are the same file: ${current_secrets_password_file}"
elif [[ -f "$current_secrets_password_file" ]]; then
    mkdir -p "$(dirname "$target_secrets_password_file")"
    cp -pf "$current_secrets_password_file" "$target_secrets_password_file" || {
        log "ERROR! failed to copy secrets.passwordFile: ${current_secrets_password_file} -> ${target_secrets_password_file}"
        exit 1
    }
    log "copied secrets.passwordFile: ${current_secrets_password_file} -> ${target_secrets_password_file}"
else
    log "WARN! skip missing secrets.passwordFile, target starter may prompt for password: ${current_secrets_password_file}"
fi

if [[ -f "$target_secrets_file" && -f "$target_secrets_password_file" ]]; then
    patch_starter_password_file_reuse "${target_dir}/scripts/starter.sh" || {
        log "ERROR! failed to patch target starter password-file handling: ${target_dir}/scripts/starter.sh"
        exit 1
    }
    log "patched target starter to reuse configured secrets.passwordFile"
fi

log "start target node: cd ${target_dir} && scripts/starter.sh"
set +e
(cd "$target_dir" && bash scripts/starter.sh) 2>&1 | tee -a "$LOGFILE"
start_status=${PIPESTATUS[0]}
set -e

if [[ $start_status -ne 0 ]]; then
    log "ERROR! failed to start target node service"
    exit 1
fi

if [[ -f "${target_dir}/scripts/health-check.sh" ]]; then
    health_check_status=0
    max_health_check_attempts=$((RETRY_TIMES + 1))

    for ((attempt = 1; attempt <= max_health_check_attempts; attempt++)); do
        if (( WAIT_SECONDS > 0 )); then
            log "wait ${WAIT_SECONDS}s before node health check attempt ${attempt}/${max_health_check_attempts}"
            sleep "$WAIT_SECONDS"
        fi

        log "health check target node attempt ${attempt}/${max_health_check_attempts}: cd ${target_dir} && scripts/health-check.sh --level all"
        if (cd "$target_dir" && bash scripts/health-check.sh --level all >> "$LOGFILE" 2>&1); then
            health_check_status=0
            break
        else
            health_check_status=$?
        fi

        log "node health check failed on attempt ${attempt}/${max_health_check_attempts} with exit code ${health_check_status}"
    done

    if [[ $health_check_status -ne 0 ]]; then
        log "ERROR! node health check failed after ${max_health_check_attempts} attempt(s)"
        exit "$health_check_status"
    fi

    log "node health check passed"
else
    log "WARN! skip node health check, script is missing: ${target_dir}/scripts/health-check.sh"
fi

log "node upgrade done: ${current_version} -> ${target_version}"
