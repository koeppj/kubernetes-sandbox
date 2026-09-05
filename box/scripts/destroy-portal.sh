#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export manifests_dir="$SCRIPT_DIR/../manifests"

microk8s kubectl delete -f "$manifests_dir/box-portal-route.yaml" --ignore-not-found=true
microk8s kubectl delete -f "$manifests_dir/box-portal-service.yaml" --ignore-not-found=true
microk8s kubectl delete -f "$manifests_dir/box-portal-deployment.yaml" --ignore-not-found=true
microk8s kubectl delete -f "$manifests_dir/box-portal-configmap.yaml" --ignore-not-found=true
microk8s kubectl -n box delete secret \
  box-portal-app-secrets \
  box-portal-oidc-config \
  box-portal-jwt-config \
  box-portal-config-file \
  --ignore-not-found=true
