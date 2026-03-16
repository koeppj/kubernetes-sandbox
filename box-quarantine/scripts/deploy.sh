#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -a
source "$SCRIPT_DIR/../.env"
set +a

export manifests_dir="$SCRIPT_DIR/../manifests"
export secrets_dir="$SCRIPT_DIR/../secrets"
export config_dir="$SCRIPT_DIR/../config"

secret_file="$secrets_dir/box-jwt-auth.json"
template_file="$config_dir/quarantine-template.txt"
normalized_secret_file=$(mktemp)

cleanup() {
  rm -f "$normalized_secret_file"
}

trap cleanup EXIT

if [ ! -f "$secret_file" ]; then
  echo "Missing Box JWT config file: $secret_file" >&2
  exit 1
fi

if [ ! -f "$template_file" ]; then
  echo "Missing quarantine template file: $template_file" >&2
  exit 1
fi

# Normalize Windows line endings before building the Kubernetes Secret.
sed 's/\r$//' "$secret_file" > "$normalized_secret_file"

envsubst < "$manifests_dir/namespace.yaml" | microk8s kubectl apply -f -
microk8s kubectl -n box-enterprise-quarantine create secret generic box-auth-config \
  --from-file=box-jwt.json="$normalized_secret_file" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl -n box-enterprise-quarantine create configmap box-quarantine-template \
  --from-file=quarantine-template.txt="$template_file" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
envsubst < "$manifests_dir/box-quarantine-state-pvc.yaml" | microk8s kubectl apply -f -
microk8s kubectl apply -f "$manifests_dir/box-quarantine-service.yaml"
envsubst < "$manifests_dir/box-quarantine-statefulset.yaml" | microk8s kubectl apply -f -
