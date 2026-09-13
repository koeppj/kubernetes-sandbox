#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
manifests_dir="$SCRIPT_DIR/../manifests"

microk8s kubectl delete --ignore-not-found -f "$manifests_dir/n8n-gateway.yaml"
microk8s kubectl delete --ignore-not-found -f "$manifests_dir/n8n-service.yaml"
microk8s kubectl delete --ignore-not-found -f "$manifests_dir/n8n-deployment.yaml"
microk8s kubectl delete --ignore-not-found -f "$manifests_dir/box-mcp-server-service.yaml"
microk8s kubectl delete --ignore-not-found -f "$manifests_dir/box-mcp-server-deployment.yaml"
microk8s kubectl delete --ignore-not-found -f "$manifests_dir/jenkins-deployer-rbac.yaml"
microk8s kubectl delete --ignore-not-found -f "$manifests_dir/postgres-statefulset.yaml"

if [[ "${1:-}" != "--purge-data" ]]; then
  echo "Workloads removed. PVCs, Secrets, ConfigMaps, and the namespace were retained."
  echo "Run $0 --purge-data only when permanent data deletion is intended."
  exit 0
fi

read -r -p "Permanently delete all n8n PVCs and the n8n namespace? Type 'delete n8n data': " confirmation
if [[ "$confirmation" != "delete n8n data" ]]; then
  echo "Data purge cancelled."
  exit 1
fi

microk8s kubectl -n n8n delete pvc \
  n8n-pv-claim \
  database-data-postgres-n8n-0 \
  database-data-v17-postgres-n8n-v17-0 \
  n8n-recovery-backup \
  --ignore-not-found
microk8s kubectl delete namespace n8n --ignore-not-found
