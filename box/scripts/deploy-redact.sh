#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

export manifests_dir="$SCRIPT_DIR/../manifests"

microk8s kubectl apply -f "$manifests_dir/namespace.yaml"
microk8s kubectl apply -f "$manifests_dir/box-redaction-service.yaml"
microk8s kubectl apply -f "$manifests_dir/box-redaction-route.yaml"
