#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-static-deploy.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${STATIC_TEST_CURL_FAIL:-0}" == 0 ]] || exit 22
site_root="$STATIC_DEPLOY_TEST_BASE/$STATIC_TEST_SITE_ID"
[[ "$(readlink "$site_root/current")" == "releases/$STATIC_TEST_EXPECTED_RELEASE" ]]
[[ -f "$site_root/current/index.html" ]]
CURL
chmod +x "$tmp_dir/bin/curl"

make_archive() {
  local root="$1" body="$2"
  local work="$tmp_dir/$root"
  mkdir -p "$work"
  printf '%s\n' "$body" > "$work/index.html"
  tar -czf "$tmp_dir/$root.tar.gz" -C "$tmp_dir" "$root"
  rm -rf "$work"
}
run_deploy() {
  local archive="$1" root="$2"
  STATIC_DEPLOY_TEST_MODE=1 \
  STATIC_DEPLOY_TEST_BASE="$tmp_dir/deploy" \
  STATIC_TEST_SITE_ID=homepage-yeying \
  STATIC_TEST_EXPECTED_RELEASE="$root" \
  PATH="$tmp_dir/bin:$PATH" \
    "$script_dir/deploy_static_artifact.sh" "$archive" homepage-yeying homepage-yeying "$root" /index.html https://example.test
}

old_root=homepage-yeying-v1.0.0-1111111
new_root=homepage-yeying-v1.1.0-2222222
make_archive "$old_root" old
run_deploy "$tmp_dir/$old_root.tar.gz" "$old_root"
[[ "$(readlink "$tmp_dir/deploy/homepage-yeying/current")" == "releases/$old_root" ]]

make_archive "$new_root" new
if STATIC_DEPLOY_TEST_MODE=1 \
  STATIC_DEPLOY_TEST_BASE="$tmp_dir/deploy" \
  STATIC_TEST_SITE_ID=homepage-yeying \
  STATIC_TEST_EXPECTED_RELEASE="$new_root" \
  STATIC_TEST_CURL_FAIL=1 \
  PATH="$tmp_dir/bin:$PATH" \
    "$script_dir/deploy_static_artifact.sh" "$tmp_dir/$new_root.tar.gz" homepage-yeying homepage-yeying "$new_root" /index.html https://example.test; then
  echo 'expected failed HTTP check to reject deployment' >&2
  exit 1
fi
[[ "$(readlink "$tmp_dir/deploy/homepage-yeying/current")" == "releases/$old_root" ]]
[[ -f "$tmp_dir/deploy/homepage-yeying/releases/$new_root/index.html" ]]
run_deploy "$tmp_dir/$new_root.tar.gz" "$new_root"
[[ "$(readlink "$tmp_dir/deploy/homepage-yeying/current")" == "releases/$new_root" ]]

conflict_root=$new_root
make_archive "$conflict_root" different-content
if STATIC_DEPLOY_TEST_MODE=1 \
  STATIC_DEPLOY_TEST_BASE="$tmp_dir/deploy" \
  STATIC_TEST_SITE_ID=homepage-yeying \
  STATIC_TEST_EXPECTED_RELEASE="$new_root" \
  PATH="$tmp_dir/bin:$PATH" \
    "$script_dir/deploy_static_artifact.sh" "$tmp_dir/$new_root.tar.gz" homepage-yeying homepage-yeying "$new_root" /index.html https://example.test; then
  echo 'expected conflicting immutable release contents to be rejected' >&2
  exit 1
fi
[[ "$(readlink "$tmp_dir/deploy/homepage-yeying/current")" == "releases/$new_root" ]]

if STATIC_DEPLOY_TEST_MODE=1 \
  STATIC_DEPLOY_TEST_BASE="$tmp_dir/invalid-path" \
  PATH="$tmp_dir/bin:$PATH" \
    "$script_dir/deploy_static_artifact.sh" "$tmp_dir/$new_root.tar.gz" homepage-yeying homepage-yeying "$new_root" /bad/../path https://example.test >/dev/null 2>&1; then
  echo 'expected unsafe health path to be rejected' >&2
  exit 1
fi

if "$script_dir/deploy_static_artifact.sh" "$tmp_dir/$new_root.tar.gz" homepage-yeying homepage-yeying-v "$new_root" /index.html https://example.test >/dev/null 2>&1; then
  echo 'expected invalid site ID to be rejected' >&2
  exit 1
fi

echo 'static deployment activation and rollback tests passed'
