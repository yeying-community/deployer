#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-auto-package.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/code" "$tmp_dir/state"
cat > "$tmp_dir/bin/flock" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$tmp_dir/bin/flock"

for repository in router homepage; do
    git init --bare --initial-branch=main "$tmp_dir/${repository}.git" >/dev/null
    git clone "$tmp_dir/${repository}.git" "$tmp_dir/code/${repository}" >/dev/null 2>&1
    git -C "$tmp_dir/code/${repository}" config user.name "Auto Package Test"
    git -C "$tmp_dir/code/${repository}" config user.email "auto-package@example.invalid"
done

publish_repository_refs() {
    local repository=$1
    git --git-dir="$tmp_dir/${repository}.git" fetch "$tmp_dir/code/${repository}" main:refs/heads/main >/dev/null 2>&1
    git --git-dir="$tmp_dir/${repository}.git" fetch "$tmp_dir/code/${repository}" 'refs/tags/*:refs/tags/*' >/dev/null 2>&1 || true
    git -C "$tmp_dir/code/${repository}" fetch origin main --tags >/dev/null 2>&1
}

mkdir -p "$tmp_dir/code/router/src" "$tmp_dir/code/homepage/wallet"
printf 'package main\n' > "$tmp_dir/code/router/src/main.go"
printf 'initial docs\n' > "$tmp_dir/code/router/README.md"
printf '<h1>Wallet</h1>\n' > "$tmp_dir/code/homepage/wallet/index.html"
printf 'initial docs\n' > "$tmp_dir/code/homepage/README.md"
for repository in router homepage; do
    git -C "$tmp_dir/code/${repository}" add .
    git -C "$tmp_dir/code/${repository}" commit -m initial >/dev/null
    publish_repository_refs "$repository"
done

cat > "$tmp_dir/auto-package.conf" <<'CONFIG'
[router]
path=src/

[homepage]
path=wallet/
CONFIG
# No manual-package.conf is created or supplied: automatic packaging must
# select repositories only from auto-package.conf.
cat > "$tmp_dir/compile-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$AUTO_PACKAGE_TEST_CALLS"
repositories_file=""
state_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repositories-file) repositories_file=$2; shift 2 ;;
        --success-state-dir) state_dir=$2; shift 2 ;;
        *) shift ;;
    esac
done
while IFS= read -r repository; do
    [[ -n "$repository" ]] || continue
    source_commit=$(git -C "$AUTO_PACKAGE_CODE_ROOT/$repository" rev-parse refs/remotes/origin/main)
    printf '%s\n' "$source_commit" > "$state_dir/$repository.source"
    rm -f "$state_dir/$repository.pending"
done < "$repositories_file"
STUB
chmod +x "$tmp_dir/compile-stub.sh"

run_auto() {
    PATH="$tmp_dir/bin:$PATH" \
    AUTO_PACKAGE_CONFIG_FILE="$tmp_dir/auto-package.conf" \
    AUTO_PACKAGE_STATE_DIR="$tmp_dir/state" \
    AUTO_PACKAGE_CODE_ROOT="$tmp_dir/code" \
    AUTO_PACKAGE_COMPILE_SCRIPT="$tmp_dir/compile-stub.sh" \
    AUTO_PACKAGE_LOCK_FILE="$tmp_dir/auto.lock" \
    AUTO_PACKAGE_LOG_FILE="$tmp_dir/auto.log" \
    AUTO_PACKAGE_TEST_CALLS="$tmp_dir/calls.log" \
        bash "$script_dir/auto_package.sh" "$@"
}

run_auto --initialize
router_initial=$(git -C "$tmp_dir/code/router" rev-parse refs/remotes/origin/main)
homepage_initial=$(git -C "$tmp_dir/code/homepage" rev-parse refs/remotes/origin/main)
[[ "$(cat "$tmp_dir/state/router.source")" == "$router_initial" ]]
[[ "$(cat "$tmp_dir/state/homepage.source")" == "$homepage_initial" ]]
[[ ! -e "$tmp_dir/calls.log" ]]

run_auto
[[ ! -e "$tmp_dir/calls.log" ]]

# A documentation-only change advances the checkpoint without publishing.
printf 'docs-only update\n' >> "$tmp_dir/code/router/README.md"
git -C "$tmp_dir/code/router" commit -am docs-only >/dev/null
publish_repository_refs router
run_auto
router_docs=$(git -C "$tmp_dir/code/router" rev-parse refs/remotes/origin/main)
[[ "$(cat "$tmp_dir/state/router.source")" == "$router_docs" ]]
[[ ! -e "$tmp_dir/calls.log" ]]

# Only the repository whose configured input path changed is selected.
printf 'package main\n// changed\n' >> "$tmp_dir/code/router/src/main.go"
git -C "$tmp_dir/code/router" commit -am source-change >/dev/null
publish_repository_refs router
printf 'homepage docs\n' >> "$tmp_dir/code/homepage/README.md"
git -C "$tmp_dir/code/homepage" commit -am docs-only >/dev/null
publish_repository_refs homepage
router_before_check=$(cat "$tmp_dir/state/router.source")
run_auto --check
[[ ! -e "$tmp_dir/calls.log" ]]
[[ "$(cat "$tmp_dir/state/router.source")" == "$router_before_check" ]]
run_auto
[[ "$(wc -l < "$tmp_dir/calls.log" | tr -d ' ')" == 1 ]]
[[ "$(cat "$tmp_dir/state/router.source")" == "$(git -C "$tmp_dir/code/router" rev-parse refs/remotes/origin/main)" ]]
[[ "$(cat "$tmp_dir/state/homepage.source")" == "$(git -C "$tmp_dir/code/homepage" rev-parse refs/remotes/origin/main)" ]]
[[ "$(cat "$tmp_dir/calls.log")" == *"router"* ]]
[[ "$(cat "$tmp_dir/calls.log")" != *"homepage"* ]]

# A recorded pending tag is retried even when there is no new source change.
router_source=$(git -C "$tmp_dir/code/router" rev-parse refs/remotes/origin/main)
git -C "$tmp_dir/code/router" tag -a v1.2.3 -m "Release v1.2.3" -m "Source-Commit: ${router_source}" >/dev/null
git --git-dir="$tmp_dir/router.git" fetch "$tmp_dir/code/router" refs/tags/v1.2.3:refs/tags/v1.2.3 >/dev/null 2>&1
printf 'v1.2.3\n%s\n' "$router_source" > "$tmp_dir/state/router.pending"
run_auto
[[ "$(wc -l < "$tmp_dir/calls.log" | tr -d ' ')" == 2 ]]
[[ "$(tail -n 1 "$tmp_dir/calls.log")" == *"--tag router:v1.2.3"* ]]
[[ ! -e "$tmp_dir/state/router.pending" ]]

# If the process stopped after tag creation, discover that tag from its source metadata.
printf 'package main\n// next change\n' >> "$tmp_dir/code/router/src/main.go"
git -C "$tmp_dir/code/router" commit -am next-source-change >/dev/null
publish_repository_refs router
router_source=$(git -C "$tmp_dir/code/router" rev-parse refs/remotes/origin/main)
git -C "$tmp_dir/code/router" tag -a v1.2.4 -m "Release v1.2.4" -m "Source-Commit: ${router_source}" >/dev/null
git --git-dir="$tmp_dir/router.git" fetch "$tmp_dir/code/router" refs/tags/v1.2.4:refs/tags/v1.2.4 >/dev/null 2>&1
run_auto
[[ "$(wc -l < "$tmp_dir/calls.log" | tr -d ' ')" == 3 ]]
[[ "$(tail -n 1 "$tmp_dir/calls.log")" == *"--tag router:v1.2.4"* ]]

printf 'automatic package change detection tests passed\n'
