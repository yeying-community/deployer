#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common/common.sh"

artifact_info_from_name warehouse warehouse-v0.0.78-24d8afd.tar.gz
[[ "$PACKAGE_VERSION" == "0.0.78" ]]
[[ "$PACKAGE_COMMIT" == "24d8afd" ]]

if artifact_info_from_name warehouse warehouse-web-v0.0.78-24d8afd.tar.gz; then
    printf '%s\n' 'warehouse service matcher accepted a warehouse-web artifact' >&2
    exit 1
fi

if artifact_info_from_name warehouse warehouse-web-v0.0.78-24d8afd; then
    printf '%s\n' 'warehouse deployment directory matcher accepted a warehouse-web artifact' >&2
    exit 1
fi

artifact_info_from_name warehouse-web warehouse-web-v0.0.78-24d8afd.tar.gz
[[ "$PACKAGE_VERSION" == "0.0.78" ]]

printf '%s\n' 'service artifact matching tests passed'
