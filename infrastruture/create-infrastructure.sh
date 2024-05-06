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
export kube_host_ip=$(curl -s -4 icanhazip.com > /dev/null)
#
# Enable plugins
#
microk8s enable community
microk8s enable registry
microk8s enable cert-manager
microk8s enable istio
microk8s enable metallb:192.168.1.243-192.168.1.254
#
# Install the CSI Driver so we can use NFS Storage
#
microk8s helm3 repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
microk8s helm3 repo update
microk8s helm3 install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
    --namespace kube-system \
    --set kubeletDir=/var/snap/microk8s/common/var/lib/kubelet
# Wait for it to be ready
microk8s kubectl wait pod --selector app.kubernetes.io/name=csi-driver-nfs --for condition=ready --namespace kube-system
#
# SpinKube Installation
#
microk8s kubectl apply -f https://github.com/spinkube/spin-operator/releases/download/v0.1.0/spin-operator.crds.yaml
microk8s kubectl apply -f https://github.com/spinkube/spin-operator/releases/download/v0.1.0/spin-operator.runtime-class.yaml
microk8s kubectl apply -f https://github.com/spinkube/spin-operator/releases/download/v0.1.0/spin-operator.shim-executor.yaml
microk8s helm repo add kwasm http://kwasm.sh/kwasm-operator/
microk8s helm install \
  kwasm-operator kwasm/kwasm-operator \
  --namespace kwasm \
  --create-namespace \
  --set kwasmOperator.installerImage=ghcr.io/spinkube/containerd-shim-spin/node-installer:v0.13.1

microk8s kubectl annotate node --all kwasm.sh/kwasm-node=true
# Install Spin Operator with Helm
microk8s helm install spin-operator \
  --namespace spin-operator \
  --create-namespace \
  --version 0.1.0 \
  --wait \
  oci://ghcr.io/spinkube/charts/spin-operator
#
# Gateway API CRUDs
#
microk8s kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml
#
# Create the docker images used
#
docker build -t localhost:32000/awsecr --push -f awsecr.Dockerfile .
docker build -t localhost:32000/awsdns --push -f awsdns.Dockerfile .
#
# Create/Update namespace
#
cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: 
    name: infrastructure
EOF
#
# Create WASM Runtime Classes for SpinKube
#
cat <<EOF | microk8s kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
    name: wasmtime-spin
handler: spin
EOF
#
# Create other resources 
#
envsubst < create-aws-credentials.yaml | kubectl apply -f -
envsubst < create-awsdns-updater.yaml | kubectl apply -f -
envsubst < aws-ecr-role-and-cron.yaml | kubectl apply -f -
kubectl apply -f create-storage-class.yaml
envsubst < create-cert-issuer.yaml | kubectl apply -f -