#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-upgrade-targets.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

config_file="$tmp_dir/upgrade-modules.conf"
static_units_config="$tmp_dir/static-units.conf"
LOGFILE="$tmp_dir/test.log"
: > "$LOGFILE"
log() { printf '%s\n' "$*"; }
usage() { :; }
load_modules() {
    local file=$1 line
    MODULES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        MODULES+=("$line")
    done < "$file"
    ((${#MODULES[@]} > 0))
}
eval "$(sed -n '/^config_has_active_rows() {/,/^}/p; /^load_upgrade_targets() {/,/^}/p' "$script_dir/upgrade.sh")"

if load_upgrade_targets; then
    echo 'expected empty target configuration to fail' >&2
    exit 1
fi

printf '# static sites only\n\n' > "$static_units_config"
if load_upgrade_targets; then
    echo 'expected comment-only static configuration to fail' >&2
    exit 1
fi

printf '# services intentionally omitted\n' > "$config_file"
printf 'homepage homepage-yeying homepage-yeying https://www.yeying.pub\nhomepage homepage-wallet homepage-wallet https://wallet.yeying.pub\n' > "$static_units_config"
load_upgrade_targets
[[ ${#MODULES[@]} -eq 0 ]]

printf 'router\n' > "$config_file"
load_upgrade_targets
[[ ${#MODULES[@]} -eq 1 && "${MODULES[0]}" == router ]]

echo 'upgrade target configuration tests passed'
