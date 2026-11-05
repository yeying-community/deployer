#!/bin/sh
# Shell-level regression tests for package_manifest.sh.
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
validator="$script_dir/package_manifest.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/package-manifest-tests.XXXXXX")
trap 'rm -rf "$tmp_dir"' 0
trap 'exit 1' HUP INT TERM
commit=0123456789abcdef0123456789abcdef01234567
version=1.2.3

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

make_fixture() {
    unit=$1
    type=$2
    mode=$3
    root="${unit}-v${version}-${commit%${commit#???????}}"
    fixture="$tmp_dir/$mode"
    mkdir -p "$fixture/staging/$root/scripts"
    if [ "$type" = service ]; then
        for name in starter.sh health-check.sh test.sh; do
            [ "$mode" != missing-entry ] || [ "$name" != starter.sh ] || continue
            printf '#!/bin/sh\nexit 0\n' > "$fixture/staging/$root/scripts/$name"
        done
    else
        printf '<html>ok</html>\n' > "$fixture/staging/$root/index.html"
    fi
    if [ "$mode" = traversal ] || [ "$mode" = unsafe-link ]; then
        ln -s ../../outside "$fixture/staging/$root/escape"
        tar -czf "$fixture/$root.tar.gz" -C "$fixture/staging" "$root"
    else
        tar -czf "$fixture/$root.tar.gz" -C "$fixture/staging" "$root"
    fi
    digest=$(sha256_file "$fixture/$root.tar.gz")
    if [ "$type" = service ]; then
        targets=null
    else
        targets='[{"site_id":"main","path":"/opt/deploy/static/main","health_check_path":"/index.html"}]'
    fi
    jq -n --arg commit "$commit" --arg version "$version" --arg unit "$unit" --arg type "$type" --arg root "$root" --arg package "$root.tar.gz" --arg sha "$digest" --argjson targets "$targets" '{schema_version:1,repository:"homepage",source_commit:$commit,artifacts:[{unit_id:$unit,type:$type,version:$version,package:$package,sha256:$sha,package_root:$root} + (if $type == "static" then {static_targets:$targets} else {} end)]}' > "$fixture/release-manifest.json"
    printf '%s\n' "$fixture"
}

fixture=$(make_fixture homepage-api service valid-service)
output=$("$validator" "$fixture/release-manifest.json" --repository homepage --source-commit "$commit" --version "$version") || fail 'valid service manifest'
[ "$output" = '{"artifacts":1,"repository":"homepage","valid":true}' ] || fail 'stable JSON summary'
pass 'valid service artifact and expected metadata'

output=$("$validator" "$fixture/release-manifest.json" --artifacts-tsv) || fail 'service TSV output'
case "$output" in "homepage-api	service	homepage-api-v1.2.3-0123456.tar.gz") ;; *) fail 'service TSV output contents' ;; esac
pass 'artifact TSV interface'

fixture=$(make_fixture homepage-yeying static valid-static)
"$validator" "$fixture/release-manifest.json" >/dev/null || fail 'valid static manifest'
pass 'valid static artifact and health entry'

if "$validator" "$fixture/release-manifest.json" --source-commit ffffffffffffffffffffffffffffffffffffffff >/dev/null 2>&1; then fail 'source commit mismatch accepted'; fi
if "$validator" "$fixture/release-manifest.json" --version 9.9.9 >/dev/null 2>&1; then fail 'version mismatch accepted'; fi
pass 'expected commit and version mismatches rejected'

jq '.artifacts[0].static_targets[0].path = "/var/www/homepage"' "$fixture/release-manifest.json" > "$fixture/bad-target.json"
if "$validator" "$fixture/bad-target.json" >/dev/null 2>&1; then fail 'non-standard static deployment path accepted'; fi
pass 'non-standard static deployment path rejected'

jq '.artifacts[0].static_targets[0].path = "/opt/deploy/static/../etc"' "$fixture/release-manifest.json" > "$fixture/traversal-target.json"
if "$validator" "$fixture/traversal-target.json" >/dev/null 2>&1; then fail 'static path traversal accepted'; fi
pass 'static deployment path traversal rejected'

fixture=$(make_fixture homepage-yeying static traversal)
if "$validator" "$fixture/release-manifest.json" >/dev/null 2>&1; then fail 'archive traversal accepted'; fi
pass 'archive path traversal rejected'

fixture=$(make_fixture homepage-api service checksum)
printf 'tamper' >> "$fixture/homepage-api-v1.2.3-0123456.tar.gz"
if "$validator" "$fixture/release-manifest.json" >/dev/null 2>&1; then fail 'checksum mismatch accepted'; fi
pass 'package digest mismatch rejected'

fixture=$(make_fixture homepage-api service duplicate)
jq '.artifacts += [.artifacts[0]]' "$fixture/release-manifest.json" > "$fixture/duplicate.json"
if "$validator" "$fixture/duplicate.json" >/dev/null 2>&1; then fail 'duplicate unit accepted'; fi
pass 'duplicate unit rejected'

fixture=$(make_fixture homepage-yeying static duplicate-site)
second_root="homepage-docs-v${version}-0123456"
mkdir -p "$fixture/staging/$second_root"
printf '<html>docs</html>\n' > "$fixture/staging/$second_root/index.html"
tar -czf "$fixture/$second_root.tar.gz" -C "$fixture/staging" "$second_root"
second_digest=$(sha256_file "$fixture/$second_root.tar.gz")
jq --arg unit homepage-docs --arg root "$second_root" --arg package "$second_root.tar.gz" --arg sha "$second_digest" \
    '.artifacts += [(.artifacts[0] | .unit_id=$unit | .package=$package | .package_root=$root | .sha256=$sha)]' \
    "$fixture/release-manifest.json" > "$fixture/duplicate-site.json"
if "$validator" "$fixture/duplicate-site.json" >/dev/null 2>&1; then fail 'duplicate static site deployment directory accepted'; fi
pass 'static site IDs unique across artifacts'

fixture=$(make_fixture homepage-api service malformed)
jq '.artifacts[0].type = []' "$fixture/release-manifest.json" > "$fixture/malformed.json"
if "$validator" "$fixture/malformed.json" >/dev/null 2>&1; then fail 'invalid field type accepted'; fi
pass 'schema field types rejected'

fixture=$(make_fixture homepage-api service missing-entry)
if "$validator" "$fixture/release-manifest.json" >/dev/null 2>&1; then fail 'service package without starter accepted'; fi
pass 'required service entry rejected when missing'

fixture=$(make_fixture homepage-api service package-link)
package_name="homepage-api-v${version}-0123456.tar.gz"
mv "$fixture/$package_name" "$fixture/real-package.tar.gz"
ln -s real-package.tar.gz "$fixture/$package_name"
if "$validator" "$fixture/release-manifest.json" >/dev/null 2>&1; then fail 'package symlink accepted'; fi
pass 'package path symlink rejected'

fixture=$(make_fixture homepage-yeying static unsafe-link)
if "$validator" "$fixture/release-manifest.json" >/dev/null 2>&1; then fail 'archive symlink with traversal target accepted'; fi
pass 'archive symlink traversal target rejected'
printf 'all package_manifest.sh tests passed\n'
