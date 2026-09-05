#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
COMPONENT_DIR="${SCRIPT_DIR}/.."
MANIFESTS_DIR="${COMPONENT_DIR}/manifests"
ENV_FILE="${COMPONENT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a
export DOLLAR='$'

envsubst < "${MANIFESTS_DIR}/postfix-tcproute.yaml" | microk8s kubectl delete --ignore-not-found -f -
envsubst < "${MANIFESTS_DIR}/postfix-deployment.yaml" | microk8s kubectl delete --ignore-not-found -f -
microk8s kubectl -n "${POSTFIX_NAMESPACE}" delete statefulset postfix --ignore-not-found
envsubst < "${MANIFESTS_DIR}/postfix-service.yaml" | microk8s kubectl delete --ignore-not-found -f -
microk8s kubectl -n "${POSTFIX_NAMESPACE}" delete pvc postfix-queue --ignore-not-found
envsubst < "${MANIFESTS_DIR}/postfix-configmap.yaml" | microk8s kubectl delete --ignore-not-found -f -
