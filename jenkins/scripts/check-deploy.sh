#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}"
  echo "Copy ${SCRIPT_DIR}/../.env.sample to ${ENV_FILE} and configure the stack first."
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

: "${JENKINS_NAMESPACE:?JENKINS_NAMESPACE is required}"

microk8s kubectl -n "${JENKINS_NAMESPACE}" get all
microk8s kubectl -n "${JENKINS_NAMESPACE}" get pvc
microk8s kubectl -n "${JENKINS_NAMESPACE}" get serviceaccount,role,rolebinding
microk8s kubectl -n "${JENKINS_NAMESPACE}" get secret aws-ecr-secret github-credentials jenkins-aws-credentials
microk8s kubectl -n "${JENKINS_NAMESPACE}" get configmap jenkins-casc
microk8s kubectl -n "${JENKINS_NAMESPACE}" get httproute
microk8s kubectl -n "${JENKINS_NAMESPACE}" logs deploy/jenkins-deployment --tail=100
