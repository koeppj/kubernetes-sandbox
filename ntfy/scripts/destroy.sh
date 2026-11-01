#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
manifests_dir="${SCRIPT_DIR}/../manifests"
purge=false
case "${1:-}" in
  '') ;;
  --purge-data) purge=true ;;
  *) echo "Usage: $0 [--purge-data]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--purge-data]" >&2; exit 2; }

microk8s kubectl delete -f "${manifests_dir}/ntfy-gateway.yaml" --ignore-not-found=true
microk8s kubectl -n ntfy delete statefulset ntfy --ignore-not-found=true --wait=true --timeout=5m
# Wait for the pod to release SQLite files before permitting data deletion.
microk8s kubectl -n ntfy wait --for=delete pod -l app=ntfy --timeout=5m
microk8s kubectl delete -f "${manifests_dir}/ntfy-service.yaml" -f "${manifests_dir}/ntfy-configmap.yaml" --ignore-not-found=true
microk8s kubectl -n ntfy delete secret ntfy --ignore-not-found=true
if [[ "$purge" == true ]]; then
  microk8s kubectl delete -f "${manifests_dir}/ntfy-pvc.yaml" --ignore-not-found=true --timeout=5m
  microk8s kubectl delete -f "${manifests_dir}/namespace.yaml" --ignore-not-found=true --timeout=5m
else
  echo 'Preserved ntfy namespace and cache/users PVCs. Use --purge-data to delete all ntfy data.'
fi
