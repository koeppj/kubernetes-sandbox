#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
COMPONENT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${COMPONENT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}" >&2
  echo "Copy ${COMPONENT_DIR}/.env.sample to ${ENV_FILE} and configure it first." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

: "${JENKINS_CONTROLLER_REPOSITORY:?JENKINS_CONTROLLER_REPOSITORY is required}"
: "${JENKINS_CONTROLLER_TAG:?JENKINS_CONTROLLER_TAG is required}"
: "${JENKINS_IMAGE:?JENKINS_IMAGE is required}"

expected_image_suffix="/${JENKINS_CONTROLLER_REPOSITORY}:${JENKINS_CONTROLLER_TAG}"

if [[ "${JENKINS_IMAGE}" != *"${expected_image_suffix}" ]]; then
  echo "JENKINS_IMAGE must end with ${expected_image_suffix}" >&2
  exit 1
fi

if ! [[ "${JENKINS_CONTROLLER_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "JENKINS_CONTROLLER_TAG is not a valid Docker tag" >&2
  exit 1
fi

docker build --tag "${JENKINS_IMAGE}" "${COMPONENT_DIR}"
docker push "${JENKINS_IMAGE}"

digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${JENKINS_IMAGE}" 2>/dev/null || true)

printf 'Published controller image: %s\nDigest: %s\n' "${JENKINS_IMAGE}" "${digest}"
