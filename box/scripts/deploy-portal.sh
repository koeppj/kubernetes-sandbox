#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -a
source "$SCRIPT_DIR/../.env"
set +a

export manifests_dir="$SCRIPT_DIR/../manifests"
export secrets_dir="$SCRIPT_DIR/../secrets"

required_files=(
  "$secrets_dir/oidc.json"
  "$secrets_dir/box-jwt-auth.json"
  "$secrets_dir/box_config.json"
)

for required_file in "${required_files[@]}"; do
  if [ ! -f "$required_file" ]; then
    echo "Missing portal secret file: $required_file" >&2
    exit 1
  fi
done

if [ -z "${PORTAL_SESSION_SECRET:-}" ] || [ "${#PORTAL_SESSION_SECRET}" -lt 16 ]; then
  echo "PORTAL_SESSION_SECRET must be set in box/.env and contain at least 16 characters." >&2
  exit 1
fi

microk8s kubectl apply -f "$manifests_dir/namespace.yaml"
microk8s kubectl -n box create secret generic box-portal-app-secrets \
  --from-literal=SESSION_SECRET="$PORTAL_SESSION_SECRET" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl -n box create secret generic box-portal-oidc-config \
  --from-file=oidc.json="$secrets_dir/oidc.json" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl -n box create secret generic box-portal-jwt-config \
  --from-file=box_jwt_config.json="$secrets_dir/box-jwt-auth.json" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl -n box create secret generic box-portal-config-file \
  --from-file=box_config.json="$secrets_dir/box_config.json" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl apply -f "$manifests_dir/box-portal-configmap.yaml"
microk8s kubectl apply -f "$manifests_dir/box-portal-deployment.yaml"
microk8s kubectl apply -f "$manifests_dir/box-portal-service.yaml"
microk8s kubectl apply -f "$manifests_dir/box-portal-route.yaml"

# Recreate the pod on every deploy so the mutable `latest` tag is fetched
# again. imagePullPolicy: Always in the Deployment enforces the pull.
microk8s kubectl -n box rollout restart deployment/box-portal
microk8s kubectl -n box rollout status deployment/box-portal
