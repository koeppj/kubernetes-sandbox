#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}" >&2
  echo "Copy ${SCRIPT_DIR}/../.env.sample to ${ENV_FILE} and fill in the live values." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a
export manifests_dir="${SCRIPT_DIR}/../manifests"
casc_dir="${SCRIPT_DIR}/../casc"

: "${JENKINS_NAMESPACE:?JENKINS_NAMESPACE is required}"
: "${JENKINS_HOSTNAME:?JENKINS_HOSTNAME is required}"
: "${JENKINS_WEBHOOK_HOSTNAME:?JENKINS_WEBHOOK_HOSTNAME is required}"
: "${JENKINS_STORAGE_CLASS:?JENKINS_STORAGE_CLASS is required}"
: "${JENKINS_STORAGE_SIZE:?JENKINS_STORAGE_SIZE is required}"
: "${JENKINS_IMAGE:?JENKINS_IMAGE is required}"
: "${JENKINS_TOOLS_IMAGE:?JENKINS_TOOLS_IMAGE is required}"
: "${JENKINS_N8N_ECR_REPOSITORY:?JENKINS_N8N_ECR_REPOSITORY is required}"
: "${JENKINS_GITHUB_OWNER:?JENKINS_GITHUB_OWNER is required}"
: "${JENKINS_GITHUB_REPOSITORY:?JENKINS_GITHUB_REPOSITORY is required}"
: "${JENKINS_HTTP_PORT:?JENKINS_HTTP_PORT is required}"
: "${JENKINS_AGENT_PORT:?JENKINS_AGENT_PORT is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION is required}"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}"
: "${JENKINS_ECR_PUSH_ACCESS_KEY_ID:?JENKINS_ECR_PUSH_ACCESS_KEY_ID is required}"
: "${JENKINS_ECR_PUSH_SECRET_ACCESS_KEY:?JENKINS_ECR_PUSH_SECRET_ACCESS_KEY is required}"
: "${JENKINS_ECR_PUSH_DEFAULT_REGION:?JENKINS_ECR_PUSH_DEFAULT_REGION is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_WEBHOOK_SECRET:?GITHUB_WEBHOOK_SECRET is required}"

export github_token_encoded
github_token_encoded=$(printf '%s' "${GITHUB_TOKEN}" | base64 | tr -d '\n')
export github_webhook_secret_encoded
github_webhook_secret_encoded=$(printf '%s' "${GITHUB_WEBHOOK_SECRET}" | base64 | tr -d '\n')
export jenkins_ecr_push_access_key_id_encoded
jenkins_ecr_push_access_key_id_encoded=$(printf '%s' "${JENKINS_ECR_PUSH_ACCESS_KEY_ID}" | base64 | tr -d '\n')
export jenkins_ecr_push_secret_access_key_encoded
jenkins_ecr_push_secret_access_key_encoded=$(printf '%s' "${JENKINS_ECR_PUSH_SECRET_ACCESS_KEY}" | base64 | tr -d '\n')
export jenkins_ecr_push_default_region_encoded
jenkins_ecr_push_default_region_encoded=$(printf '%s' "${JENKINS_ECR_PUSH_DEFAULT_REGION}" | base64 | tr -d '\n')
export JENKINS_CASC_INDENTED
JENKINS_CASC_INDENTED=$(sed 's/^/    /' "${casc_dir}/jenkins.yaml")

envsubst < "${manifests_dir}/namespace.yaml" | microk8s kubectl apply -f -

ecr_registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
ecr_password=$(aws ecr get-login-password --region "${AWS_DEFAULT_REGION}")
microk8s kubectl -n "${JENKINS_NAMESPACE}" create secret docker-registry aws-ecr-secret \
  --docker-server="${ecr_registry}" \
  --docker-username=AWS \
  --docker-password="${ecr_password}" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
unset ecr_password

envsubst < "${manifests_dir}/github-credentials-secret.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/aws-credentials-secret.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/jenkins-pvc.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/jenkins-rbac.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/jenkins-casc-configmap.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/jenkins-deployment.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/jenkins-service.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/jenkins-gateway.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/jenkins-webhook-gateway.yaml" | microk8s kubectl apply -f -
