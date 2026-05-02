#!/bin/bash

set -euo pipefail

NAMESPACE="infrastructure"
CRONJOB_NAME="aws-ecr-secret-update"
JOB_NAME="${CRONJOB_NAME}-manual-$(date +%Y%m%d%H%M%S)"

microk8s kubectl -n "${NAMESPACE}" create job "${JOB_NAME}" --from="cronjob/${CRONJOB_NAME}"

echo "Started job ${JOB_NAME} from cronjob/${CRONJOB_NAME} in namespace ${NAMESPACE}."
echo "Watch it with: microk8s kubectl -n ${NAMESPACE} logs -f job/${JOB_NAME}"
