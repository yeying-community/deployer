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

service_artifact_info_from_name chat chat-service-v0.0.97-76e5888.tar.gz
[[ "$PACKAGE_VERSION" == "0.0.97" ]]
service_artifact_info_from_name chat chat-standalone-v0.0.96-b75eb0d
[[ "$PACKAGE_VERSION" == "0.0.96" ]]
if service_artifact_info_from_name chat chat-desktop-v0.0.97-76e5888.zip; then
    printf '%s\n' 'service matcher accepted a desktop artifact' >&2
    exit 1
fi

printf '%s\n' 'service artifact matching tests passed'
