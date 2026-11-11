#!/usr/bin/env bash
# upload or download one package file between /opt/package and WebDAV directory

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" || exit 1; pwd)
# shellcheck disable=SC1091
source "${script_dir}/../common/common.sh"

init_log_file "transfer-packages.log"

env_file="${WEBDAV_PACKAGE_ENV_FILE:-${script_dir}/.env}"
package_root="/opt/package"
webdav_dir_url=""
AUTH_ARGS=()

usage() {
    log "Usage:"
    log "  $0 upload <filename>"
    log "  $0 download <filename>"
    log "Notes:"
    log "  - local directory is fixed to ${package_root}"
    log "  - auth is read from ${env_file}"
    log "  - remote dir: WEBDAV_PACKAGE_BASE_URL"
}

load_webdav_config() {
    local base_url

    if [[ ! -f "$env_file" ]]; then
        log "ERROR! env file is missing: ${env_file}"
        return 1
    fi

    # shellcheck disable=SC1090
    set -a
    source "$env_file"
    set +a

    if [[ -z "${WEBDAV_PACKAGE_AK:-}" || -z "${WEBDAV_PACKAGE_SK:-}" ]]; then
        log "ERROR! set WEBDAV_PACKAGE_AK and WEBDAV_PACKAGE_SK in ${env_file}."
        return 1
    fi

    base_url=$(trim "${WEBDAV_PACKAGE_BASE_URL:-}")

    base_url="${base_url%/}"

    if [[ -z "$base_url" ]]; then
        log "ERROR! set WEBDAV_PACKAGE_BASE_URL in ${env_file}."
        return 1
    fi

    AUTH_ARGS=(-u "${WEBDAV_PACKAGE_AK}:${WEBDAV_PACKAGE_SK}")
    webdav_dir_url="$base_url"
}

build_remote_url() {
    local dir_url=$1
    local target_name=$2
    local encoded_name

    encoded_name=$(urlencode_component "$target_name") || return 1
    printf '%s/%s' "${dir_url%/}" "$encoded_name"
}

ensure_remote_dir_recursive() {
    local dir_url=$1
    local status check_status

    check_status=$(curl -sS -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" "${AUTH_ARGS[@]}" "$dir_url")
    case "$check_status" in
        200|207|301|302|307|308)
            return 0
            ;;
        401|403)
            log "ERROR! authentication failed while checking remote dir: ${dir_url}"
            return 1
            ;;
    esac

    status=$(curl -sS -o /dev/null -w "%{http_code}" -X MKCOL "${AUTH_ARGS[@]}" "$dir_url")
    case "$status" in
        200|201|204|301|302|307|308|405)
            return 0
            ;;
        401|403)
            log "ERROR! authentication failed while ensuring remote dir: ${dir_url}"
            return 1
            ;;
        409)
            log "ERROR! parent directory is missing for remote dir: ${dir_url}"
            return 1
            ;;
        *)
            log "ERROR! failed to ensure remote dir ${dir_url}, mkcol=${status}, propfind=${check_status}"
            return 1
            ;;
    esac

    return 0
}

if [[ $# -eq 1 ]]; then
    arg1=$(trim "$1")
    if [[ "$arg1" == "-h" || "$arg1" == "--help" ]]; then
        usage
        exit 0
    fi
fi

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

operation=$(trim "$1")
filename=$(trim "$2")

if [[ -z "$operation" || -z "$filename" ]]; then
    usage
    exit 1
fi

if [[ "$filename" == */* ]]; then
    log "ERROR! filename only, path is not allowed: ${filename}"
    exit 1
fi

load_webdav_config || exit 1
mkdir -p "$package_root"

remote_file_url=$(build_remote_url "$webdav_dir_url" "$filename") || {
    log "ERROR! failed to build remote url for ${filename}"
    exit 1
}

case "$operation" in
    upload)
        local_file="${package_root}/${filename}"
        if [[ ! -f "$local_file" ]]; then
            log "ERROR! local file is missing: ${local_file}"
            exit 2
        fi

        if ! ensure_remote_dir_recursive "$webdav_dir_url"; then
            exit 4
        fi

        log "upload file: ${local_file} -> ${remote_file_url}"
        upload_body_file=$(mktemp "/tmp/upload_${filename//[^A-Za-z0-9._-]/_}.XXXXXX")
        upload_status=$(curl -sS -o "$upload_body_file" -w "%{http_code}" \
            -X PUT "${AUTH_ARGS[@]}" --data-binary @"$local_file" "$remote_file_url")

        case "$upload_status" in
            200|201|204)
                rm -f "$upload_body_file"
                log "upload success: ${filename}"
                ;;
            401|403)
                rm -f "$upload_body_file"
                log "ERROR! authentication failed during upload: ${filename}"
                exit 4
                ;;
            301|302|307|308)
                rm -f "$upload_body_file"
                log "ERROR! upload redirected (http ${upload_status}), set exact WEBDAV_DIR_URL in ${env_file}"
                exit 4
                ;;
            404)
                rm -f "$upload_body_file"
                log "ERROR! remote path not found: ${webdav_dir_url}/"
                exit 4
                ;;
            412)
                rm -f "$upload_body_file"
                log "ERROR! target file already exists: ${remote_file_url}"
                exit 4
                ;;
            *)
                if [[ -s "$upload_body_file" ]]; then
                    log "server response: $(tr '\n' ' ' < "$upload_body_file" | head -c 500)"
                fi
                rm -f "$upload_body_file"
                log "ERROR! upload failed for ${filename}, http status ${upload_status}"
                exit 4
                ;;
        esac
        ;;
    download)
        tmpfile=$(mktemp "/tmp/${filename//[^A-Za-z0-9._-]/_}.XXXXXX")
        download_body_file=$(mktemp "/tmp/download_${filename//[^A-Za-z0-9._-]/_}.XXXXXX")
        log "download file: ${remote_file_url}"
        download_status=$(curl -sS -o "$tmpfile" -w "%{http_code}" "${AUTH_ARGS[@]}" "$remote_file_url")
        case "$download_status" in
            200|206)
                rm -f "$download_body_file"
                mv -f "$tmpfile" "${package_root}/${filename}"
                log "download success: ${package_root}/${filename}"
                ;;
            401|403)
                rm -f "$download_body_file"
                rm -f "$tmpfile"
                log "ERROR! authentication failed during download: ${filename}"
                exit 5
                ;;
            404)
                rm -f "$download_body_file"
                rm -f "$tmpfile"
                log "ERROR! remote file not found: ${filename}"
                exit 5
                ;;
            *)
                # For non-success, file content may be error text; print part of it.
                cp -f "$tmpfile" "$download_body_file" 2>/dev/null || true
                if [[ -s "$download_body_file" ]]; then
                    log "server response: $(tr '\n' ' ' < "$download_body_file" | head -c 500)"
                fi
                rm -f "$download_body_file"
                rm -f "$tmpfile"
                log "ERROR! download failed for ${filename}, http status ${download_status}"
                exit 5
                ;;
        esac
        ;;
    *)
        usage
        exit 1
        ;;
esac
