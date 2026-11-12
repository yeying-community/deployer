#!/usr/bin/env bash

LOGFILE=""
MODULES=()
AUTH_ARGS=()
WEBDAV_PACKAGE_BASE_URL=""
WEBDAV_DIR_URL=""
PACKAGE_VERSION=""
PACKAGE_COMMIT=""
PACKAGE_VERSION_KEY=""
PACKAGE_STEM=""
SELECTED_NAME=""
SELECTED_VERSION=""
SELECTED_COMMIT=""
SELECTED_VERSION_KEY=""
EXTRACTED_DIR=""

init_log_file() {
    local logfile_name=$1
    local logfile_dir="/opt/logs"

    LOGFILE="${logfile_dir}/${logfile_name}"
    mkdir -p "$logfile_dir"
    touch "$LOGFILE"

    local filesize=0
    filesize=$(stat -c "%s" "$LOGFILE" 2>/dev/null || echo 0)
    if [[ "$filesize" -ge 1048576 ]]; then
        printf 'clear old logs at %s to avoid log file too big\n' "$(date)" > "$LOGFILE"
    fi
}

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log_err() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE" >&2
}

trim() {
    local value=$1
    value="${value//$'\r'/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

load_modules() {
    local config_file=$1
    shift

    MODULES=()

    if [[ $# -gt 0 ]]; then
        local item trimmed_item
        for item in "$@"; do
            trimmed_item=$(trim "$item")
            if [[ -n "$trimmed_item" ]]; then
                MODULES+=("$trimmed_item")
            fi
        done
    else
        if [[ ! -f "$config_file" ]]; then
            log "ERROR! config file (${config_file}) is missing."
            return 1
        fi

        local line trimmed_line
        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed_line=$(trim "$line")
            if [[ -z "$trimmed_line" || "$trimmed_line" == \#* ]]; then
                continue
            fi
            MODULES+=("$trimmed_line")
        done < "$config_file"
    fi

    if [[ ${#MODULES[@]} -eq 0 ]]; then
        log "ERROR! module list is empty."
        return 1
    fi
}

load_webdav_env() {
    local env_file=$1

    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$env_file"
        set +a
    fi

    WEBDAV_PACKAGE_BASE_URL="$(trim "${WEBDAV_PACKAGE_BASE_URL:-}")"
    WEBDAV_PACKAGE_BASE_URL="${WEBDAV_PACKAGE_BASE_URL%/}"

    if [[ -z "${WEBDAV_PACKAGE_AK:-}" || -z "${WEBDAV_PACKAGE_SK:-}" ]]; then
        log "ERROR! set WEBDAV_PACKAGE_AK and WEBDAV_PACKAGE_SK in ${env_file}."
        return 1
    fi

    if [[ -z "$WEBDAV_PACKAGE_BASE_URL" ]]; then
        log "ERROR! set WEBDAV_PACKAGE_BASE_URL in ${env_file}."
        return 1
    fi

    AUTH_ARGS=("-u" "${WEBDAV_PACKAGE_AK}:${WEBDAV_PACKAGE_SK}")
    WEBDAV_DIR_URL="$WEBDAV_PACKAGE_BASE_URL"
}

urlencode_component() {
    python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1]))
PY
}

remote_url_for_file() {
    local filename=$1
    local encoded_name

    encoded_name=$(urlencode_component "$filename") || return 1
    printf '%s/%s' "$WEBDAV_DIR_URL" "$encoded_name"
}

webdav_ensure_remote_dir() {
    local status

    status=$(curl -sS -o /dev/null -w "%{http_code}" -X MKCOL "${AUTH_ARGS[@]}" "${WEBDAV_DIR_URL}/")
    case "$status" in
        200|201|204|301|302|307|308|405)
            return 0
            ;;
        401|403)
            log "ERROR! authentication failed for ${WEBDAV_DIR_URL}/"
            return 1
            ;;
        *)
            log "ERROR! failed to ensure remote directory (${WEBDAV_DIR_URL}/), http status ${status}"
            return 1
            ;;
    esac
}

webdav_list_files() {
    local response status body

    response=$(curl -sS -X PROPFIND -H "Depth: 1" "${AUTH_ARGS[@]}" "${WEBDAV_DIR_URL}/" -w "\n%{http_code}")
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    case "$status" in
        200|207)
            ;;
        401|403)
            log_err "ERROR! authentication failed for ${WEBDAV_DIR_URL}/"
            return 1
            ;;
        404)
            log_err "ERROR! remote directory not found: ${WEBDAV_DIR_URL}/"
            return 1
            ;;
        *)
            log_err "ERROR! failed to list remote directory (${WEBDAV_DIR_URL}/), http status ${status}"
            return 1
            ;;
    esac

    printf '%s' "$body" | python3 -c '
import os
import sys
import urllib.parse
import xml.etree.ElementTree as ET

data = sys.stdin.read()
if not data.strip():
    sys.exit(0)

try:
    root = ET.fromstring(data)
except Exception:
    sys.exit(0)

seen = set()

def emit(name: str) -> None:
    if not name or name in seen:
        return
    seen.add(name)
    print(name)

for elem in root.iter():
    if elem.text is None:
        continue
    text = elem.text.strip()
    if not text:
        continue
    if elem.tag.endswith("displayname"):
        emit(text)
        continue
    if elem.tag.endswith("href"):
        parsed = urllib.parse.urlparse(text)
        path = parsed.path if parsed.scheme else text
        path = urllib.parse.unquote(path)
        name = os.path.basename(path.rstrip("/"))
        emit(name)
'
}

artifact_info_from_name() {
    local module_name=$1
    local item=${2%/}
    local base rest version_tag version commit major minor patch prefix

    base=$(basename "$item")
    if [[ "$base" == *.tar.gz ]]; then
        base=${base%.tar.gz}
    fi

    if [[ "$base" != "${module_name}-"* ]]; then
        return 1
    fi

    commit=${base##*-}
    rest=${base%-${commit}}
    rest=${rest%-}
    version_tag=${rest##*-}
    prefix=${rest%-${version_tag}}
    prefix=${prefix%-}

    if [[ "$prefix" != "$module_name" ]]; then
        return 1
    fi
    if [[ ! "$version_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    version=${version_tag#v}
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    if [[ ! "$commit" =~ ^[0-9A-Za-z]{7}$ ]]; then
        return 1
    fi

    IFS='.' read -r major minor patch <<< "$version"

    PACKAGE_VERSION="$version"
    PACKAGE_COMMIT="$commit"
    PACKAGE_STEM="$base"
    printf -v PACKAGE_VERSION_KEY '%09d%09d%09d' "$major" "$minor" "$patch"
    return 0
}

version_key_from_version() {
    local version=$1
    local major minor patch

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi

    IFS='.' read -r major minor patch <<< "$version"
    printf '%09d%09d%09d' "$major" "$minor" "$patch"
}

version_gt() {
    local left_key right_key

    left_key=$(version_key_from_version "$1") || return 1
    right_key=$(version_key_from_version "$2") || return 1
    [[ "$left_key" > "$right_key" ]]
}

select_latest_named_item() {
    local module_name=$1
    shift

    SELECTED_NAME=""
    SELECTED_VERSION=""
    SELECTED_COMMIT=""
    SELECTED_VERSION_KEY=""

    local item selected_stem=""
    for item in "$@"; do
        if ! artifact_info_from_name "$module_name" "$item"; then
            continue
        fi

        if [[ -z "$SELECTED_NAME" || "$PACKAGE_VERSION_KEY" > "$SELECTED_VERSION_KEY" || ( "$PACKAGE_VERSION_KEY" == "$SELECTED_VERSION_KEY" && "$PACKAGE_STEM" > "$selected_stem" ) ]]; then
            SELECTED_NAME="$(basename "${item%/}")"
            SELECTED_VERSION="$PACKAGE_VERSION"
            SELECTED_COMMIT="$PACKAGE_COMMIT"
            SELECTED_VERSION_KEY="$PACKAGE_VERSION_KEY"
            selected_stem="$PACKAGE_STEM"
        fi
    done

    [[ -n "$SELECTED_NAME" ]]
}

select_latest_by_fixed_short_commit() {
    local module_name=$1
    shift
    select_latest_named_item "$module_name" "$@"
}

archive_top_dir() {
    python3 - "$1" <<'PY'
import sys
import tarfile

archive_path = sys.argv[1]

try:
    with tarfile.open(archive_path, "r:gz") as tar:
        for member in tar.getmembers():
            name = member.name.lstrip("./")
            if not name:
                continue
            top_dir = name.split("/", 1)[0]
            if top_dir and top_dir != ".":
                print(top_dir)
                break
except Exception:
    sys.exit(1)
PY
}

ensure_extracted_dir() {
    local archive_file=$1
    local target_root=$2
    local expected_dir_name=${3:-}
    local top_dir

    top_dir=$(archive_top_dir "$archive_file") || {
        log "ERROR! failed to inspect archive: ${archive_file}"
        return 1
    }

    if [[ -z "$top_dir" ]]; then
        log "ERROR! archive is empty: ${archive_file}"
        return 1
    fi

    if [[ -n "$expected_dir_name" && "$top_dir" != "$expected_dir_name" ]]; then
        log "ERROR! archive top directory mismatch, expected ${expected_dir_name}, got ${top_dir}"
        return 1
    fi

    mkdir -p "$target_root"
    if [[ ! -d "${target_root}/${top_dir}" ]]; then
        tar -xzf "$archive_file" -C "$target_root"
    fi

    EXTRACTED_DIR="${target_root}/${top_dir}"
}
