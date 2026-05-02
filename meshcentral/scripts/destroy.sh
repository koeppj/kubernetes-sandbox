#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -a
source "${SCRIPT_DIR}/../.env"
set +a
export manifests_dir="${SCRIPT_DIR}/../manifests"

envsubst < "${manifests_dir}/meshcentral-gateway.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/meshcentral-service.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/meshcentral-deployment.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/meshcentral-pvc.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
microk8s kubectl delete secret meshcentral-config -n "${MESH_NAMESPACE}" --ignore-not-found=true
envsubst < "${manifests_dir}/namespace.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
