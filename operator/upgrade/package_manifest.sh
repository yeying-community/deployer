#!/bin/sh
# Validate a release manifest and its packages with jq and system tools.
set -u
LC_ALL=C
export LC_ALL

UNIT_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
COMMIT_RE='^[0-9a-f]{40}$'
SHA_RE='^[0-9a-f]{64}$'

fail() { printf 'manifest validation failed: %s\n' "$1" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: package_manifest.sh MANIFEST [--repository ID] [--source-commit SHA]
       [--version VERSION] [--packages-only | --artifacts-tsv]
Requires jq, tar, and sha256sum or shasum.
HELP
}

manifest=
expected_repository=
expected_source_commit=
expected_version=
packages_only=0
artifacts_tsv=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --repository|--source-commit|--version)
            option=$1
            shift
            [ "$#" -gt 0 ] || fail "$option requires a value"
            case "$option" in
                --repository) expected_repository=$1 ;;
                --source-commit) expected_source_commit=$1 ;;
                --version) expected_version=$1 ;;
            esac
            ;;
        --packages-only) packages_only=1 ;;
        --artifacts-tsv) artifacts_tsv=1 ;;
        --) shift; [ "$#" -eq 1 ] || fail 'expected one manifest path'; manifest=$1; break ;;
        -*) fail "unknown option: $1" ;;
        *) [ -z "$manifest" ] || fail 'only one manifest path is allowed'; manifest=$1 ;;
    esac
    shift
done

[ -n "$manifest" ] || { usage >&2; exit 2; }
[ "$packages_only" -eq 0 ] || [ "$artifacts_tsv" -eq 0 ] || fail '--packages-only and --artifacts-tsv are mutually exclusive'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v tar >/dev/null 2>&1 || fail 'tar is required'
if command -v sha256sum >/dev/null 2>&1; then sha_command=sha256sum
elif command -v shasum >/dev/null 2>&1; then sha_command=shasum
else fail 'sha256sum or shasum is required'
fi
[ -f "$manifest" ] || fail "manifest file does not exist: $manifest"
manifest_dir=$(dirname "$manifest")
output_dir=$(CDPATH= cd -P "$manifest_dir" 2>/dev/null && pwd -P) || fail "cannot resolve manifest directory: $manifest_dir"

jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || fail 'manifest root must be an object'
jq -e '.schema_version | type == "number" and tojson == "1"' "$manifest" >/dev/null 2>&1 || fail 'schema_version must be 1'
if ! jq -e --arg unit "$UNIT_RE" --arg ver "$VERSION_RE" --arg commit "$COMMIT_RE" --arg sha "$SHA_RE" '
    (.repository | type == "string" and test($unit)) and
    (.source_commit | type == "string" and test($commit)) and
    (.artifacts | type == "array" and length > 0) and
    all(.artifacts[];
        . as $a |
        ($a | type == "object") and
        ($a.unit_id | type == "string" and test($unit)) and
        ($a.type | type == "string" and (["service", "service-with-assets", "static", "desktop"] | index($a.type) != null)) and
        ($a.version | type == "string" and test($ver)) and
        ($a.package | type == "string" and endswith(".tar.gz") and (contains("/") | not) and (contains("\\") | not)) and
        ($a.sha256 | type == "string" and test($sha)) and
        ($a.package_root | type == "string" and length > 0 and (contains("/") | not) and (contains("\\") | not)) and
        (if $a.type == "static" then
            ($a.static_targets | type == "array" and length > 0) and
            ([$a.static_targets[].site_id] | unique | length == ($a.static_targets | length)) and
            all($a.static_targets[];
                . as $t |
                ($t | type == "object") and
                ($t.site_id | type == "string" and test($unit)) and
                ($t.path | type == "string" and . == ("/opt/deploy/static/" + $t.site_id)) and
                ($t.health_check_path | type == "string" and startswith("/") and (contains("//") | not) and (test("(^|/)\\.\\.(/|$)") | not) and (contains("\\\\") | not) and (explode | all(.[]; . >= 32 and . != 127)))
            )
        else true end)
    )
' "$manifest" >/dev/null 2>&1; then
    fail 'manifest fields do not match schema version 1'
fi

repository=$(jq -r '.repository' "$manifest")
source_commit=$(jq -r '.source_commit' "$manifest")
[ -z "$expected_repository" ] || [ "$repository" = "$expected_repository" ] || fail "repository mismatch: expected $expected_repository, got $repository"
[ -z "$expected_source_commit" ] || [ "$source_commit" = "$expected_source_commit" ] || fail 'source_commit does not match the selected build commit'
if [ -n "$expected_version" ] && ! printf '%s\n' "$expected_version" | grep -Eq "$VERSION_RE"; then fail 'requested version must use major.minor.patch format'; fi
artifact_count=$(jq -r '.artifacts | length' "$manifest")
unit_count=$(jq -r '[.artifacts[].unit_id] | unique | length' "$manifest")
[ "$artifact_count" -eq "$unit_count" ] || fail 'duplicate unit_id'
package_count=$(jq -r '[.artifacts[].package] | unique | length' "$manifest")
[ "$artifact_count" -eq "$package_count" ] || fail 'duplicate package'
static_site_count=$(jq -r '[.artifacts[] | select(.type == "static") | .static_targets[].site_id] | length' "$manifest")
unique_static_site_count=$(jq -r '[.artifacts[] | select(.type == "static") | .static_targets[].site_id] | unique | length' "$manifest")
[ "$static_site_count" -eq "$unique_static_site_count" ] || fail 'duplicate static site_id would target the same deployment directory'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/package-manifest.XXXXXX") || fail 'cannot create temporary directory'
trap 'rm -rf "$tmp_dir"' 0
trap 'exit 1' HUP INT TERM
archive_list="$tmp_dir/archive.list"
archive_verbose="$tmp_dir/archive.verbose"
sha256_file() {
    if [ "$sha_command" = sha256sum ]; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'
    fi
}
archive_has_entry() { awk -v wanted="$1" '$0 == wanted { found=1 } END { exit !found }' "$archive_list"; }

index=0
while [ "$index" -lt "$artifact_count" ]; do
    unit_id=$(jq -r --argjson i "$index" '.artifacts[$i].unit_id' "$manifest")
    artifact_type=$(jq -r --argjson i "$index" '.artifacts[$i].type' "$manifest")
    version=$(jq -r --argjson i "$index" '.artifacts[$i].version' "$manifest")
    package_name=$(jq -r --argjson i "$index" '.artifacts[$i].package' "$manifest")
    package_root=$(jq -r --argjson i "$index" '.artifacts[$i].package_root' "$manifest")
    checksum=$(jq -r --argjson i "$index" '.artifacts[$i].sha256' "$manifest")
    if [ -n "$expected_version" ] && [ "$version" != "$expected_version" ]; then fail "artifacts[$index].version does not match the requested release version"; fi
    short_commit=$(printf '%s\n' "$source_commit" | cut -c 1-7)
    expected_package="${unit_id}-v${version}-${short_commit}.tar.gz"
    [ "$package_name" = "$expected_package" ] || fail "artifacts[$index].package must be $expected_package"
    [ "$package_root" = "${package_name%.tar.gz}" ] || fail "artifacts[$index].package_root must match the package name without .tar.gz"
    package_path="$output_dir/$package_name"
    if [ -L "$package_path" ] || [ ! -f "$package_path" ]; then fail "package does not exist as a regular file: $package_name"; fi
    actual_checksum=$(sha256_file "$package_path") || fail "cannot compute SHA-256 for $package_name"
    [ "$actual_checksum" = "$checksum" ] || fail "SHA-256 mismatch for $package_name"
    tar -tzf "$package_path" >"$archive_list" 2>/dev/null || fail "cannot read archive $package_name"
    [ -s "$archive_list" ] || fail "archive is empty: $package_name"
    while IFS= read -r member || [ -n "$member" ]; do
        case "$member" in ''|/*|..|../*|*/../*|*/..) fail "archive contains an unsafe path: $member" ;; esac
        member_root=${member%%/*}
        [ "$member_root" = "$package_root" ] || fail "archive entry is outside package_root $package_root: $member"
    done < "$archive_list"
    tar -tvzf "$package_path" >"$archive_verbose" 2>/dev/null || fail "cannot inspect archive $package_name"
    while IFS= read -r listing || [ -n "$listing" ]; do
        case "$listing" in
            l*' -> '*) link_target=${listing##* -> } ;;
            *' link to '*) link_target=${listing##* link to } ;;
            *) continue ;;
        esac
        case "$link_target" in ''|/*|..|../*|*/../*|*/..) fail "archive contains an unsafe link target: $link_target" ;; esac
    done < "$archive_verbose"
    case "$artifact_type" in
        service|service-with-assets)
            for required in "$package_root/scripts/starter.sh" "$package_root/scripts/health-check.sh" "$package_root/scripts/test.sh"; do
                archive_has_entry "$required" || fail "$package_name is missing required service file: $required"
            done
            ;;
        static)
            target_count=$(jq -r --argjson i "$index" '.artifacts[$i].static_targets | length' "$manifest")
            target_index=0
            while [ "$target_index" -lt "$target_count" ]; do
                health_path=$(jq -r --argjson i "$index" --argjson j "$target_index" '.artifacts[$i].static_targets[$j].health_check_path' "$manifest")
                entry_path=${health_path#/}
                [ -n "$entry_path" ] || entry_path=index.html
                archive_entry="$package_root/$entry_path"
                archive_has_entry "$archive_entry" || fail "$package_name is missing static health-check entry: $archive_entry"
                target_index=$((target_index + 1))
            done
            ;;
    esac
    index=$((index + 1))
done

if [ "$artifacts_tsv" -eq 1 ]; then
    jq -r '.artifacts[] | [.unit_id, .type, .package] | @tsv' "$manifest"
elif [ "$packages_only" -eq 1 ]; then
    jq -r '.artifacts[].package' "$manifest"
else
    jq -cnS --arg repository "$repository" --argjson artifacts "$artifact_count" '{valid:true, repository:$repository, artifacts:$artifacts}'
fi
