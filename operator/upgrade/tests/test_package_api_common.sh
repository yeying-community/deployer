#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-package-api-common.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
fixture="$tmp_dir/fixture"
mkdir -p "$fixture/scripts"
cp "$repo_root/node/scripts/package-common.sh" "$fixture/scripts/package-common.sh"
cat > "$fixture/build.sh" <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/scripts/package-common.sh"
package_common_init fixture "$@"
package_make_root fixture-service
mkdir -p "$PACKAGE_DIR/scripts"
for file in starter.sh health-check.sh test.sh; do printf '#!/bin/sh\nexit 0\n' > "$PACKAGE_DIR/scripts/$file"; done
package_finish_artifact service
package_finish
BUILD
chmod +x "$fixture/build.sh"
git -C "$fixture" init -q
git -C "$fixture" config user.email fixture@example.test
git -C "$fixture" config user.name fixture
git -C "$fixture" add .
git -C "$fixture" commit -qm fixture
commit="$(git -C "$fixture" rev-parse HEAD)"
mkdir -p "$tmp_dir/output"
(cd "$fixture" && ./build.sh --ref "$commit" --version 1.2.3 --output-dir "$tmp_dir/output")
"$script_dir/package_manifest.sh" "$tmp_dir/output/release-manifest.json" --repository fixture --source-commit "$commit" --version 1.2.3 >/dev/null
[[ -f "$tmp_dir/output/fixture-service-v1.2.3-${commit:0:7}.tar.gz" ]]
if (cd "$fixture" && ./build.sh --ref "$commit" --version 1.2.3 --output-dir "$tmp_dir/output") >/dev/null 2>&1; then
  echo 'expected non-empty output directory to be rejected' >&2
  exit 1
fi
echo 'shared package API manifest generation and output protection tests passed'
