#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-compile-profile.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

eval "$(sed -n '/^load_host_profile() {/,/^}/p' "$script_dir/compile_packages.sh")"

profile_file="$tmp_dir/profile"
cat > "$profile_file" <<'PROFILE'
: "${XDG_DATA_DIRS}"
PROFILE_TEST_PATH="/opt/test-tools/bin:${PATH}"
export PROFILE_TEST_PATH
PROFILE

unset XDG_DATA_DIRS PROFILE_TEST_PATH
load_host_profile "$profile_file"

[[ "${PROFILE_TEST_PATH%%:*}" == "/opt/test-tools/bin" ]]
[[ "$-" == *e* && "$-" == *u* ]]
[[ "$(set -o | awk '$1 == "pipefail" { print $2 }')" == on ]]

echo 'compile host profile tolerates optional unset variables and preserves strict mode'
