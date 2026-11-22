#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$script_dir/../common/common.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-active-host-release.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
deploy_root="$tmp_dir/deploy"
mkdir -p "$deploy_root/tester-service-v0.1.5-8360a1f" \
  "$deploy_root/tester-service-v0.1.6-9865d39-host57a529489391-shell"
ln -s tester-service-v0.1.6-9865d39-host57a529489391-shell "$deploy_root/tester"
log() { :; }

eval "$(sed -n '/^find_current_version_from_deploy_dirs() {/,/^}/p' "$script_dir/upgrade.sh")"

find_current_version_from_deploy_dirs tester
[[ "$SELECTED_NAME" == "tester-service-v0.1.6-9865d39-host57a529489391-shell" ]]
[[ "$SELECTED_VERSION" == "0.1.6" ]]
[[ "$SELECTED_COMMIT" == "9865d39" ]]
[[ "$PACKAGE_ADAPTATION_SUFFIX" == "-host57a529489391-shell" ]]

current_dir="${deploy_root}/${SELECTED_NAME}"
[[ "$(readlink -f "$current_dir")" == "$(readlink -f "$deploy_root/tester")" ]]
[[ -f "$current_dir" || -d "$current_dir" ]]

printf '%s\n' 'active host-overlay release resolution tests passed'
