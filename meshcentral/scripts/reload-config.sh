#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -a
source "${SCRIPT_DIR}/../.env"
set +a
export secrets_dir="${SCRIPT_DIR}/../secrets"

if [ ! -f "${secrets_dir}/config.json" ]; then
  echo "Missing ${secrets_dir}/config.json"
  echo "Copy ${secrets_dir}/config.json.sample to ${secrets_dir}/config.json and fill in the live values."
  exit 1
fi

microk8s kubectl create secret generic meshcentral-config \
  -n "${MESH_NAMESPACE}" \
  --from-file=config.json="${secrets_dir}/config.json" \
  --dry-run=client \
  -o yaml | microk8s kubectl apply -f -

microk8s kubectl rollout restart deploy/meshcentral -n "${MESH_NAMESPACE}"
microk8s kubectl rollout status deploy/meshcentral -n "${MESH_NAMESPACE}"
