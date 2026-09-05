#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
COMPONENT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${COMPONENT_DIR}/.env"
MANIFESTS_DIR="${COMPONENT_DIR}/manifests"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}; copy .env.sample and configure it first." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a
export DOLLAR='$'

: "${POSTFIX_NAMESPACE:?POSTFIX_NAMESPACE is required}"
: "${POSTFIX_IMAGE:?POSTFIX_IMAGE is required}"
: "${POSTFIX_INCOMING_MAILBOX:?POSTFIX_INCOMING_MAILBOX is required}"
: "${POSTFIX_DESTINATION_MAILBOX:?POSTFIX_DESTINATION_MAILBOX is required}"

case "${POSTFIX_INCOMING_MAILBOX}" in
  *[[:space:]]*)
    echo "POSTFIX_INCOMING_MAILBOX must not contain whitespace" >&2
    exit 1
    ;;
esac

# The virtual alias map is a Postfix regexp table. Escape the configured
# address so that it is matched literally and remains a single-recipient gate.
POSTFIX_INCOMING_MAILBOX_REGEX=$(printf '%s' "${POSTFIX_INCOMING_MAILBOX}" | sed 's/[.[\\*^$()+?{|}]/\\&/g; s/]/\\]/g; s#/#\\/#g')
export POSTFIX_INCOMING_MAILBOX_REGEX

if [ "${POSTFIX_BUILD_IMAGE:-true}" = "true" ]; then
  "${SCRIPT_DIR}/build.sh"
fi

envsubst < "${MANIFESTS_DIR}/namespace.yaml" | microk8s kubectl apply -f -
envsubst < "${MANIFESTS_DIR}/postfix-configmap.yaml" | microk8s kubectl apply -f -
envsubst < "${MANIFESTS_DIR}/postfix-service.yaml" | microk8s kubectl apply -f -
# Remove the former controller if this is an upgrade from the PVC-backed demo.
microk8s kubectl -n "${POSTFIX_NAMESPACE}" delete statefulset postfix --ignore-not-found
envsubst < "${MANIFESTS_DIR}/postfix-deployment.yaml" | microk8s kubectl apply -f -
envsubst < "${MANIFESTS_DIR}/postfix-tcproute.yaml" | microk8s kubectl apply -f -
