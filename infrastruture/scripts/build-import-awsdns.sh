#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
infrastructure_dir=$(cd -- "$SCRIPT_DIR/.." && pwd)
image="awsdns:1.0.0"
archive_dir=$(mktemp -d -t awsdns-import.XXXXXXXX)
archive_path="$archive_dir/awsdns.tar"
import_log="$archive_dir/import.log"
trap 'rm -f -- "$archive_path" "$import_log"; rmdir -- "$archive_dir"' EXIT

docker build -t "$image" -f "$infrastructure_dir/awsdns.Dockerfile" "$infrastructure_dir"
docker save -o "$archive_path" "$image"
# Some MicroK8s versions print per-node failures but still exit successfully.
PYTHONUNBUFFERED=1 microk8s images import < "$archive_path" 2>&1 | tee "$import_log"
if grep -Eq 'Failed to (import images on|reach)|Could not query for nodes' "$import_log"; then
    echo "AWS DNS image import failed; deployment must not proceed." >&2
    exit 1
fi
