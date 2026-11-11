#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-auto-package-state.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

eval "$(sed -n '/^write_auto_pending_tag() {/,/^}/p; /^write_auto_success_state() {/,/^}/p' "$script_dir/compile_packages.sh")"

source_one=0123456789abcdef0123456789abcdef01234567
source_two=abcdef0123456789abcdef0123456789abcdef01
write_auto_pending_tag "$tmp_dir/state" router v1.2.3 "$source_one"
[[ "$(sed -n '1p' "$tmp_dir/state/router.pending")" == v1.2.3 ]]
[[ "$(sed -n '2p' "$tmp_dir/state/router.pending")" == "$source_one" ]]
[[ "$(sed -n '3p' "$tmp_dir/state/router.pending")" == 1 ]]
write_auto_pending_tag "$tmp_dir/state" router v1.2.3 "$source_one"
[[ "$(sed -n '3p' "$tmp_dir/state/router.pending")" == 2 ]]

# Completing an unrelated later source must preserve the older pending tag.
write_auto_success_state "$tmp_dir/state" router "$source_two"
[[ -f "$tmp_dir/state/router.pending" ]]
[[ "$(cat "$tmp_dir/state/router.source")" == "$source_two" ]]

# Completing the pending tag's own source clears it atomically after checkpointing.
write_auto_success_state "$tmp_dir/state" router "$source_one"
[[ ! -e "$tmp_dir/state/router.pending" ]]
[[ "$(cat "$tmp_dir/state/router.source")" == "$source_one" ]]

if write_auto_pending_tag "$tmp_dir/state" '../router' v1.2.4 "$source_one"; then
    echo 'invalid repository name unexpectedly accepted' >&2
    exit 1
fi

echo 'automatic package pending and success state tests passed'
