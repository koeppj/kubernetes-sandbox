#!/bin/bash
#
# Pull AWS region, key id and key from ~/.aws files and
# put into current k8s namespace
#
# First check if aliases are used
if [ -f ~/.bash_aliases ]; then
    shopt -s expand_aliases
    source ~/.bash_aliases
fi
#
# Create the docker image used by teh aws ecr updater job
#
docker build -t localhost:32000/awsecr --push .
#
# Create/Update namespace
#
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: 
    name: infrastructure
EOF
aws_access_key_id=$(sed -rn '/aws_access_key_id = /p' ~/.aws/credentials | cut -d '=' -f2 | tr -d '[:space:]' | base64)
aws_secret_access_key=$(sed -rn '/aws_secret_access_key = /p' ~/.aws/credentials | cut -d '=' -f2 | tr -d '[:space:]' | base64)
aws_default_region=$(sed -rn '/region = /p' ~/.aws/config | cut -d '=' -f2 | tr -d '[:space:]' | base64)
cat <<EOF | kubectl apply -f - 
apiVersion: v1
kind: Secret
metadata:
    name: aws-credentials
    namespace: infrastructure
type: Opaque
data:
    AWS_ACCESS_KEY_ID: ${aws_access_key_id}
    AWS_SECRET_ACCESS_KEY: ${aws_secret_access_key}
    AWS_DEFAULT_REGION: ${aws_default_region}
EOF
kubectl apply -f aws-ecr-role-and-cron.yaml