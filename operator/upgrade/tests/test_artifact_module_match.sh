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
service_artifact_info_from_name tester tester-service-v0.1.6-9865d39-host57a529489391-shell
[[ "$PACKAGE_VERSION" == "0.1.6" ]]
[[ "$PACKAGE_COMMIT" == "9865d39" ]]
[[ "$PACKAGE_ADAPTATION_SUFFIX" == "-host57a529489391-shell" ]]
if service_artifact_info_from_name tester tester-service-v0.1.6-9865d39-host57a529489391-shell.tar.gz; then
    printf '%s\n' 'service matcher accepted a host-overlay suffix in a remote archive' >&2
    exit 1
fi
service_artifact_info_from_name router router-v0.0.163-b1a9d54
[[ "$PACKAGE_VERSION" == "0.0.163" ]]
if service_artifact_info_from_name chat chat-standalone-v0.0.96-b75eb0d; then
    printf '%s\n' 'service matcher accepted a retired chat-standalone directory' >&2
    exit 1
fi
if service_artifact_info_from_name chat chat-desktop-v0.0.97-76e5888.zip; then
    printf '%s\n' 'service matcher accepted a desktop artifact' >&2
    exit 1
fi
select_latest_service_named_item chat chat-v0.0.97-76e5888.tar.gz chat-service-v0.0.97-76e5888.tar.gz
[[ "$SELECTED_NAME" == chat-service-v0.0.97-76e5888.tar.gz ]]

printf '%s\n' 'service artifact matching tests passed'
