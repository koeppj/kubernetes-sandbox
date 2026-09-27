#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -a
source "${SCRIPT_DIR}/../.env"
set +a
export manifests_dir="${SCRIPT_DIR}/../manifests"
export secrets_dir="${SCRIPT_DIR}/../secrets"

pvc_states="$(python3 "$SCRIPT_DIR/../../nfs-ha/scripts/verify-migrated-claims.py" \
  "$MESH_NAMESPACE" meshcentral-data)"

if [ ! -f "${secrets_dir}/config.json" ]; then
  echo "Missing ${secrets_dir}/config.json"
  echo "Copy ${secrets_dir}/config.json.sample to ${secrets_dir}/config.json and fill in the live values."
  exit 1
fi

envsubst < "${manifests_dir}/namespace.yaml" | microk8s kubectl apply -f -

microk8s kubectl create secret generic meshcentral-config \
  -n "${MESH_NAMESPACE}" \
  --from-file=config.json="${secrets_dir}/config.json" \
  --dry-run=client \
  -o yaml | microk8s kubectl apply -f -

if grep -qx 'meshcentral-data NEW' <<< "$pvc_states"; then
  envsubst < "${manifests_dir}/meshcentral-pvc.yaml" | microk8s kubectl apply -f -
else
  echo 'Preserving verified meshcentral/meshcentral-data binding.'
fi
envsubst < "${manifests_dir}/meshcentral-deployment.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/meshcentral-service.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/meshcentral-gateway.yaml" | microk8s kubectl apply -f -
