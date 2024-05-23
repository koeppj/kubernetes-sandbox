#!/bin/bash
#
# Get project root.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source $SCRIPT_DIR/../.env

export aws_access_key_id_encoded=$(echo ${aws_access_key_id} | tr -d '[:space:]' | base64)
export aws_secret_access_key_encoded=$(echo ${aws_secret_access_key} | tr -d '[:space:]' | base64)
export aws_default_region_encoded=$(echo ${aws_default_region} | tr -d '[:space:]' | base64)
export aws_account_id_encoded=$(echo ${aws_account_id} | tr -d '[:space:]' | base64)

microk8s kubectl apply -f jenkins-resources.yaml
envsubst < create-aws-credentials.yaml | microk8s kubectl apply -f -
