#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export manifests_dir="$SCRIPT_DIR/../manifests"

microk8s kubectl delete -f "$manifests_dir/box-quarantine-statefulset.yaml" --ignore-not-found=true
microk8s kubectl delete -f "$manifests_dir/box-quarantine-service.yaml" --ignore-not-found=true
microk8s kubectl delete -f "$manifests_dir/box-quarantine-state-pvc.yaml" --ignore-not-found=true
microk8s kubectl -n box-enterprise-quarantine delete configmap box-quarantine-template --ignore-not-found=true
microk8s kubectl -n box-enterprise-quarantine delete secret box-auth-config --ignore-not-found=true
microk8s kubectl delete -f "$manifests_dir/namespace.yaml" --ignore-not-found=true
