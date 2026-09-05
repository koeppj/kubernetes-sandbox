#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
COMPONENT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${COMPONENT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}; copy .env.sample and configure it first." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

: "${POSTFIX_IMAGE:?POSTFIX_IMAGE is required}"
: "${POSTFIX_IMAGE_TAG:?POSTFIX_IMAGE_TAG is required}"

if [[ "${POSTFIX_IMAGE}" != *":${POSTFIX_IMAGE_TAG}" ]]; then
  echo "POSTFIX_IMAGE must end in :${POSTFIX_IMAGE_TAG}" >&2
  exit 1
fi

docker build --tag "${POSTFIX_IMAGE}" "${COMPONENT_DIR}"
docker push "${POSTFIX_IMAGE}"
printf 'Published Postfix image: %s\n' "${POSTFIX_IMAGE}"
