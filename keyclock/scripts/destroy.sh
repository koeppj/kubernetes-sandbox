#!/bin/bash

#
# Get project root and manifests dir.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export manifests_dir=$SCRIPT_DIR/../manifests

microk8s kubectl delete -f ${manifests_dir}/keycloak-gateway.yaml --ignore-not-found=true
microk8s kubectl delete -f ${manifests_dir}/keycloak-service.yaml --ignore-not-found=true
microk8s kubectl delete -f ${manifests_dir}/keycloak-deployment.yaml --ignore-not-found=true
microk8s kubectl delete -f ${manifests_dir}/keycloak-pvc.yaml --ignore-not-found=true
microk8s kubectl delete -f ${manifests_dir}/keycloak-secret.yaml --ignore-not-found=true
microk8s kubectl delete -f ${manifests_dir}/postgres-statefulset.yaml --ignore-not-found=true
microk8s kubectl delete -f ${manifests_dir}/postgres-configmap.yaml --ignore-not-found=true
microk8s kubectl delete -f ${manifests_dir}/postgres-secret.yaml --ignore-not-found=true

# Explicit PVC cleanup (safe if already removed by manifest delete above).
microk8s kubectl delete pvc -n keycloak keycloak-data --ignore-not-found=true

# StatefulSet PVCs are created dynamically from volumeClaimTemplates.
for pvc in $(microk8s kubectl get pvc -n keycloak -o name | grep '^persistentvolumeclaim/database-data-postgres-keycloak-' || true); do
  microk8s kubectl delete -n keycloak "${pvc}" --ignore-not-found=true
done
