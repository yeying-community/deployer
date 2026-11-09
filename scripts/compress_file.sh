#!/usr/bin/env bash
# this script is used to compress the specified folder into a tar.gz file.
# haiqinma - 20251101 - first version

set -u
set -o pipefail

if [ $# -eq 0 ]; then
    echo "please specified folder or file"
    exit 1
fi

if [ ! -e "$1" ]; then
    echo "please an exists folder or file"
    exit 2
fi
directory_name=$(basename "$1")
directory_path=$(dirname "$1")

compress_name="${directory_name}-$(date +%Y%m%d-%H%M%S).tar.gz"

cd "${directory_path}" || exit 3
tar -czf "${compress_name}" "${directory_name}"
cd - || exit 4