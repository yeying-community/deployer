#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-package-sync.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

LOGFILE="$tmp_dir/test.log"
: > "$LOGFILE"
log() { printf '%s\n' "$*"; }
eval "$(sed -n '/^sync_main_latest() {/,/^}/p' "$script_dir/compile_packages.sh")"

git init --bare --initial-branch=main "$tmp_dir/origin.git" >/dev/null
git clone "$tmp_dir/origin.git" "$tmp_dir/router" >/dev/null 2>&1
git clone "$tmp_dir/origin.git" "$tmp_dir/publisher" >/dev/null 2>&1
for repo in "$tmp_dir/router" "$tmp_dir/publisher"; do
    git -C "$repo" config user.name "Package Sync Test"
    git -C "$repo" config user.email "package-sync@example.invalid"
done

printf 'initial\n' > "$tmp_dir/publisher/source.txt"
git -C "$tmp_dir/publisher" add source.txt
git -C "$tmp_dir/publisher" commit -m initial >/dev/null
git --git-dir="$tmp_dir/origin.git" fetch "$tmp_dir/publisher" main:refs/heads/main >/dev/null 2>&1
git -C "$tmp_dir/router" fetch origin main >/dev/null 2>&1
git -C "$tmp_dir/router" merge --ff-only origin/main >/dev/null

printf 'fast-forward\n' >> "$tmp_dir/publisher/source.txt"
git -C "$tmp_dir/publisher" commit -am upstream-update >/dev/null
git --git-dir="$tmp_dir/origin.git" fetch "$tmp_dir/publisher" main:refs/heads/main >/dev/null 2>&1
sync_main_latest router "$tmp_dir/router"
[[ "$(git -C "$tmp_dir/router" rev-parse HEAD)" == "$(git -C "$tmp_dir/router" rev-parse origin/main)" ]]
[[ "$(cat "$tmp_dir/router/source.txt")" == $'initial\nfast-forward' ]]

printf 'preserve me\n' > "$tmp_dir/router/local.txt"
if sync_main_latest router "$tmp_dir/router"; then
    echo 'dirty worktree unexpectedly accepted' >&2
    exit 1
fi
[[ -f "$tmp_dir/router/local.txt" ]]
[[ "$(git -C "$tmp_dir/router" rev-parse HEAD)" != "$(git -C "$tmp_dir/router" rev-parse origin/main)" ]]

rm "$tmp_dir/router/local.txt"
printf 'local commit\n' >> "$tmp_dir/router/source.txt"
git -C "$tmp_dir/router" commit -am local-only >/dev/null
printf 'remote commit\n' >> "$tmp_dir/publisher/source.txt"
git -C "$tmp_dir/publisher" commit -am remote-only >/dev/null
git --git-dir="$tmp_dir/origin.git" fetch "$tmp_dir/publisher" main:refs/heads/main >/dev/null 2>&1
local_head="$(git -C "$tmp_dir/router" rev-parse HEAD)"
if sync_main_latest router "$tmp_dir/router"; then
    echo 'diverged worktree unexpectedly accepted' >&2
    exit 1
fi
[[ "$(git -C "$tmp_dir/router" rev-parse HEAD)" == "$local_head" ]]

printf 'compile_packages safe fast-forward tests passed\n'
