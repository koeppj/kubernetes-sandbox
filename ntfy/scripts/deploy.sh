#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
if (($#)); then
  echo "Usage: $0" >&2
  exit 2
fi
source "${SCRIPT_DIR}/common.sh"
prepare_environment

microk8s kubectl get storageclass kube-nfs >/dev/null
microk8s kubectl -n infrastructure get gateway johnkoepp-com-gateway >/dev/null
for manifest in namespace.yaml ntfy-secret.yaml ntfy-configmap.yaml ntfy-pvc.yaml ntfy-service.yaml ntfy-statefulset.yaml ntfy-gateway.yaml; do
  render_manifest "$manifest" | microk8s kubectl apply -f -
done
microk8s kubectl -n ntfy rollout status statefulset/ntfy --timeout=5m

# Verify discovery using the actual deployed pod template and PVC classes.
nfs_targets=$("${SCRIPT_DIR}/../../bin/shutdown-nfs-workloads.sh" --dry-run)
printf '%s\n' "$nfs_targets"
if ! grep -Eq 'statefulset[[:space:]]+ntfy/ntfy:' <<< "$nfs_targets"; then
  echo 'NFS maintenance did not discover ntfy/ntfy; review before NFS maintenance.' >&2
  exit 1
fi
