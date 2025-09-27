#!/bin/bash

#
# Get project root and manifests dir.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export manifests_dir=$SCRIPT_DIR/../manifests

microk8s kubectl delete -f ${manifests_dir}/n8n-gateway.yaml
microk8s kubectl delete -f ${manifests_dir}/n8n-service.yaml
microk8s kubectl delete -f ${manifests_dir}/n8n-deployment.yaml
microk8s kubectl delete -f ${manifests_dir}/n8n-persistent-volume-claim.yaml
microk8s kubectl delete -f ${manifests_dir}/postgres-statefulset.yaml
microk8s kubectl delete -f ${manifests_dir}/postgres-configmap.yaml
microk8s kubectl delete -f ${manifests_dir}/postgres-secret.yaml
microk8s kubectl delete -f ${manifests_dir}/namespace.yaml