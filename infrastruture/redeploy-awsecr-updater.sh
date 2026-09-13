#!/bin/bash
set -euo pipefail
#
# Get project root.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source "$SCRIPT_DIR/../.env"
: "${ecrtoken_issuer_schedule:?Set ecrtoken_issuer_schedule in the project .env}"
export ecrtoken_issuer_schedule
"$SCRIPT_DIR/scripts/build-import-awsecr.sh"
envsubst '${ecrtoken_issuer_schedule}' < "$SCRIPT_DIR/aws-ecr-role-and-cron.yaml" | microk8s kubectl apply -f -
