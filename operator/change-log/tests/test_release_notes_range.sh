#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-range.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/homepage"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name "Release Test"
git -C "$repo" config user.email "release-test@example.invalid"
printf 'first\n' > "$repo/source.txt"
git -C "$repo" add source.txt
git -C "$repo" commit -qm 'initial release source'
first_source="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" tag -a v0.0.1 -m "Release v0.0.1" -m "Source-Commit: $first_source"

printf 'second\n' >> "$repo/source.txt"
git -C "$repo" commit -qam 'homepage feature'
second_source="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" tag -a v0.0.2 -m "Release v0.0.2" -m "Source-Commit: $second_source"

# Source the script to exercise range resolution without invoking Codex or touching production paths.
# shellcheck source=../release_notes.sh
source "$repo_root/operator/change-log/release_notes.sh"

old_ref=""
new_ref=""
target_ref=""
resolve_release_range "$repo" v0.0.2 "$second_source"
[[ "$old_ref" == "$first_source" ]]
[[ "$new_ref" == "$second_source" ]]
[[ "$target_ref" == v0.0.2 ]]

release_identity=""
resolve_default_range "$repo" >/dev/null 2>&1 && {
  echo 'default range unexpectedly resolved without an origin tracking ref' >&2
  exit 1
}

echo 'release notes source-commit range tests passed'
