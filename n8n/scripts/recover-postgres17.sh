#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
manifests_dir="$SCRIPT_DIR/../manifests"

for job in n8n-postgres-pre-pg17-backup n8n-files-pre-pg17-backup; do
  completed=$(microk8s kubectl -n n8n get job "$job" -o jsonpath='{.status.succeeded}')
  if [[ "$completed" != "1" ]]; then
    echo "Required verified backup Job $job has not completed." >&2
    exit 1
  fi
done

if microk8s kubectl -n n8n get job n8n-postgres-v17-restore >/dev/null 2>&1; then
  echo "Restore Job already exists; refusing to run a second restore into the same database." >&2
  exit 1
fi

microk8s kubectl apply -f "$manifests_dir/postgres-configmap.yaml"
microk8s kubectl apply -f "$manifests_dir/postgres-statefulset.yaml"
microk8s kubectl -n n8n rollout status statefulset/postgres-n8n-v17 --timeout=5m

microk8s kubectl apply -f "$manifests_dir/postgres-restore-job.yaml"
if ! microk8s kubectl -n n8n wait \
  --for=condition=complete \
  job/n8n-postgres-v17-restore \
  --timeout=10m; then
  microk8s kubectl -n n8n logs job/n8n-postgres-v17-restore || true
  exit 1
fi
microk8s kubectl -n n8n logs job/n8n-postgres-v17-restore

new_pv=$(microk8s kubectl -n n8n get pvc database-data-v17-postgres-n8n-v17-0 -o jsonpath='{.spec.volumeName}')
test -n "$new_pv"
microk8s kubectl patch pv "$new_pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

microk8s kubectl -n n8n scale statefulset/postgres-n8n --replicas=0
microk8s kubectl apply -f "$manifests_dir/n8n-deployment.yaml"
microk8s kubectl -n n8n rollout status deployment/n8n --timeout=5m
