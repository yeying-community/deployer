#!/usr/bin/env bash
# Install a validated static artifact under /opt/deploy/static/<site_id> and
# atomically update current. The caller validates release-manifest.json first.
set -euo pipefail

usage() {
  printf 'Usage: %s PACKAGE.tar.gz UNIT_ID SITE_ID PACKAGE_ROOT HEALTH_CHECK_PATH HEALTH_BASE_URL\n' "$(basename "$0")" >&2
}

[[ $# -eq 6 ]] || { usage; exit 2; }
archive=$1
unit_id=$2
site_id=$3
package_root=$4
health_path=$5
health_base_url=$6

[[ -f "$archive" && ! -L "$archive" ]] || { echo 'static package must be a regular file' >&2; exit 1; }
[[ "$unit_id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo 'invalid unit_id' >&2; exit 1; }
[[ "$site_id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo 'invalid site_id' >&2; exit 1; }
[[ "$package_root" == "${unit_id}-v"* ]] || { echo 'package_root must begin with the unit_id' >&2; exit 1; }
[[ "$package_root" =~ ^${unit_id}-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-[0-9a-f]{7}$ ]] || { echo 'invalid static package_root' >&2; exit 1; }
[[ "$health_path" == /* && ! "$health_path" =~ (^|/)\.\.(/|$) && ! "$health_path" =~ // && ! "$health_path" == *\\* ]] || { echo 'invalid static health path' >&2; exit 1; }
[[ "$health_base_url" =~ ^https?://[^[:space:]]+$ ]] || { echo 'health base URL must use HTTP or HTTPS' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo 'tar is required' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'curl is required' >&2; exit 1; }

if [[ "${STATIC_DEPLOY_TEST_MODE:-0}" == 1 ]]; then
  [[ -n "${STATIC_DEPLOY_TEST_BASE:-}" ]] || { echo 'STATIC_DEPLOY_TEST_BASE is required in test mode' >&2; exit 1; }
  static_base="$(mkdir -p "$STATIC_DEPLOY_TEST_BASE" && cd "$STATIC_DEPLOY_TEST_BASE" && pwd -P)"
else
  static_base=/opt/deploy/static
fi
site_root="$static_base/$site_id"
release_dir="$site_root/releases/$package_root"
health_file="${health_path#/}"
[[ -n "$health_file" ]] || health_file=index.html

archive_list=$(mktemp "${TMPDIR:-/tmp}/static-package-list.XXXXXX")
archive_verbose=$(mktemp "${TMPDIR:-/tmp}/static-package-verbose.XXXXXX")
stage_dir=''
next_link=''
cleanup() {
  [[ -z "$stage_dir" || ! -d "$stage_dir" ]] || rm -rf -- "$stage_dir"
  [[ -z "$next_link" || ! -L "$next_link" ]] || rm -f -- "$next_link"
  rm -f -- "$archive_list" "$archive_verbose"
}
trap cleanup EXIT HUP INT TERM

tar -tzf "$archive" > "$archive_list" || { echo 'unable to read static archive' >&2; exit 1; }
[[ -s "$archive_list" ]] || { echo 'static archive is empty' >&2; exit 1; }
while IFS= read -r member || [[ -n "$member" ]]; do
  case "$member" in
    ''|/*|..|../*|*/../*|*/..) echo "unsafe archive path: $member" >&2; exit 1 ;;
  esac
  root=${member%%/*}
  [[ "$root" == "$package_root" ]] || { echo "archive entry outside package root: $member" >&2; exit 1; }
done < "$archive_list"
tar -tvzf "$archive" > "$archive_verbose" || { echo 'unable to inspect static archive' >&2; exit 1; }
while IFS= read -r listing || [[ -n "$listing" ]]; do
  case "$listing" in
    l*|h*) echo 'static archive must not contain symlinks or hard links' >&2; exit 1 ;;
  esac
done < "$archive_verbose"
awk -v wanted="$package_root/$health_file" '$0 == wanted { found=1 } END { exit !found }' "$archive_list" || {
  echo "static archive is missing health entry: $health_file" >&2
  exit 1
}

mkdir -p "$site_root/releases"
[[ ! -e "$site_root/current" || -L "$site_root/current" ]] || { echo 'current exists and is not a symlink' >&2; exit 1; }
if [[ -L "$site_root/current" ]]; then
  current_target=$(readlink "$site_root/current")
  [[ "$current_target" == releases/* && "$current_target" != *'..'* ]] || { echo 'current points outside the release directory' >&2; exit 1; }
  [[ -d "$site_root/$current_target" ]] || { echo 'current points to a missing release' >&2; exit 1; }
else
  current_target=''
fi

stage_dir=$(mktemp -d "$site_root/releases/.${package_root}.XXXXXX")
tar -xzf "$archive" -C "$stage_dir"
[[ -d "$stage_dir/$package_root" && ! -L "$stage_dir/$package_root" ]] || { echo 'archive did not create its expected package root' >&2; exit 1; }
if [[ -d "$release_dir" ]]; then
  if ! diff -qr "$stage_dir/$package_root" "$release_dir" >/dev/null; then
    echo "refusing to reuse immutable release with different contents: $package_root" >&2
    exit 1
  fi
  rm -rf -- "$stage_dir"
  stage_dir=''
else
  mv "$stage_dir/$package_root" "$release_dir"
  rmdir "$stage_dir"
  stage_dir=''
fi
[[ -f "$release_dir/$health_file" && ! -L "$release_dir/$health_file" ]] || { echo 'installed release health entry is missing or is a symlink' >&2; exit 1; }

next_link="$site_root/.current.$$"
ln -s "releases/$package_root" "$next_link"
mv -f "$next_link" "$site_root/current"
next_link=''
if ! curl --fail --silent --show-error --max-time "${STATIC_HEALTH_TIMEOUT_SECONDS:-15}" "${health_base_url%/}${health_path}" >/dev/null; then
  echo "HTTP health check failed after activating $package_root" >&2
  if [[ -n "$current_target" ]]; then
    rollback_link="$site_root/.current.rollback.$$"
    ln -s "$current_target" "$rollback_link"
    mv -f "$rollback_link" "$site_root/current"
  else
    rm -f "$site_root/current"
  fi
  exit 1
fi
printf 'Activated %s at %s/current\n' "$package_root" "$site_root"
