#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(sed -n '/^release_manifest_filename() {/,/^}/p' "$script_dir/compile_packages.sh")"

source_commit=0123456789abcdef0123456789abcdef01234567
release_commit=abcdef0123456789abcdef0123456789abcdef01
actual=$(release_manifest_filename homepage 0.0.3 "$source_commit")
expected=release-manifest-homepage-v0.0.3-0123456.json
[[ "$actual" == "$expected" ]] || {
    printf 'expected %s, got %s\n' "$expected" "$actual" >&2
    exit 1
}
[[ "$actual" != "release-manifest-homepage-v0.0.3-${release_commit:0:7}.json" ]] || {
    echo 'manifest filename unexpectedly uses the release commit' >&2
    exit 1
}

echo 'compile manifest filename source-commit test passed'
