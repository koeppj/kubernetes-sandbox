#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a
export manifests_dir="${SCRIPT_DIR}/../manifests"
: "${JENKINS_NAMESPACE:?JENKINS_NAMESPACE is required}"

purge_data=false
if [ "${1:-}" = "--purge-data" ]; then
  purge_data=true
elif [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--purge-data]" >&2
  exit 1
fi

envsubst < "${manifests_dir}/jenkins-webhook-gateway.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/jenkins-gateway.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/jenkins-service.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/jenkins-deployment.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/jenkins-casc-configmap.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
envsubst < "${manifests_dir}/jenkins-rbac.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
microk8s kubectl delete secret github-credentials jenkins-aws-credentials aws-ecr-secret -n "${JENKINS_NAMESPACE}" --ignore-not-found=true

if [ "${purge_data}" = true ]; then
  envsubst < "${manifests_dir}/jenkins-pvc.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
  envsubst < "${manifests_dir}/namespace.yaml" | microk8s kubectl delete -f - --ignore-not-found=true
else
  echo "Jenkins workload removed; PVC ${JENKINS_NAMESPACE}/jenkins-pv-claim was preserved."
fi
