#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="infrastructure"
CRONJOB_NAME="aws-ecr-secret-update"
JOB_NAME="${CRONJOB_NAME}-manual-$(date +%Y%m%d%H%M%S)-$$"

if ! microk8s kubectl -n "${NAMESPACE}" get cronjob "${CRONJOB_NAME}" >/dev/null; then
  echo "CronJob ${NAMESPACE}/${CRONJOB_NAME} was not found." >&2
  exit 1
fi

microk8s kubectl -n "${NAMESPACE}" create job "${JOB_NAME}" --from="cronjob/${CRONJOB_NAME}"

echo "Started job ${JOB_NAME} from cronjob/${CRONJOB_NAME} in namespace ${NAMESPACE}."

if microk8s kubectl -n "${NAMESPACE}" wait --for=condition=complete --timeout=5m "job/${JOB_NAME}"; then
  microk8s kubectl -n "${NAMESPACE}" logs "job/${JOB_NAME}"
  echo "AWS ECR pull-secret refresh completed successfully."
else
  echo "AWS ECR pull-secret refresh did not complete successfully." >&2
  microk8s kubectl -n "${NAMESPACE}" describe "job/${JOB_NAME}" >&2 || true
  microk8s kubectl -n "${NAMESPACE}" logs "job/${JOB_NAME}" >&2 || true
  exit 1
fi
