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

: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}"
: "${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION is required}"
: "${JENKINS_TOOLS_REPOSITORY:?JENKINS_TOOLS_REPOSITORY is required}"
: "${JENKINS_TOOLS_TAG:?JENKINS_TOOLS_TAG is required}"
: "${JENKINS_TOOLS_IMAGE:?JENKINS_TOOLS_IMAGE is required}"

expected_image="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${JENKINS_TOOLS_REPOSITORY}:${JENKINS_TOOLS_TAG}"
if [ "${JENKINS_TOOLS_IMAGE}" != "${expected_image}" ]; then
  echo "JENKINS_TOOLS_IMAGE must equal ${expected_image}" >&2
  exit 1
fi

if ! [[ "${JENKINS_TOOLS_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "JENKINS_TOOLS_TAG is not a valid Docker tag" >&2
  exit 1
fi

docker build --file "${COMPONENT_DIR}/tools.Dockerfile" --tag "${JENKINS_TOOLS_IMAGE}" "${COMPONENT_DIR}"
docker push "${JENKINS_TOOLS_IMAGE}"

digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${JENKINS_TOOLS_IMAGE}" 2>/dev/null || true)
printf 'Published tools image: %s\nDigest: %s\n' "${JENKINS_TOOLS_IMAGE}" "${digest}"
