#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -a
source "${SCRIPT_DIR}/../.env"
set +a

microk8s kubectl -n "${MESH_NAMESPACE}" get all
microk8s kubectl -n "${MESH_NAMESPACE}" get pvc
microk8s kubectl -n "${MESH_NAMESPACE}" get secret meshcentral-config
microk8s kubectl -n "${MESH_NAMESPACE}" get httproute
microk8s kubectl -n "${MESH_NAMESPACE}" logs deploy/meshcentral
