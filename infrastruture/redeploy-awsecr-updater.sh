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
export kube_host_ip=$(curl -s -4 icanhazip.com)
docker build -t localhost:32000/awsecr --push -f awsecr.Dockerfile .
envsubst < aws-ecr-role-and-cron.yaml | microk8s kubectl delete -f -
envsubst < aws-ecr-role-and-cron.yaml | microk8s kubectl apply -f -
