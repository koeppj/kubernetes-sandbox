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

case "${1:-status}" in
  preview)
    for manifest in namespace postfix-configmap postfix-service postfix-deployment postfix-tcproute; do
      envsubst < "${MANIFESTS_DIR}/${manifest}.yaml"
      printf '%s\n' '---'
    done
    ;;
  status)
    microk8s kubectl -n "${POSTFIX_NAMESPACE}" rollout status deployment/postfix --timeout=180s
    microk8s kubectl -n "${POSTFIX_NAMESPACE}" get deployment postfix
    microk8s kubectl -n "${POSTFIX_NAMESPACE}" get tcproute postfix-smtp -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}:{.reason}{"\\n"}{end}'
    microk8s kubectl -n infrastructure get gateway johnkoepp-com-gateway -o jsonpath='{range .status.listeners[?(@.name=="smtp")].conditions[*]}{.type}={.status}:{.reason}{"\\n"}{end}'
    ;;
  *)
    echo "Usage: $0 [preview|status]" >&2
    exit 2
    ;;
esac
