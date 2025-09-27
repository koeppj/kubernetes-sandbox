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
export kube_host_ip=$(curl -s -4 icanhazip.com)
#
# Enable plugins
#
microk8s enable community
microk8s enable rbac
microk8s enable cert-manager
microk8s enable metallb:192.168.1.243-192.168.1.254
// Patch metallb to only advertise on wired interfaces
microk8s kubectl -n metallb-system patch l2advertisement default-advertise-all-pools \
  --type merge \
  -p '{
    "spec": {
      "nodeSelectors": [
        {
          "matchLabels": {
            "net": "wired"
          }
        }
      ]
    }
  }'

microk8s enable registry
microk8s enable metrics-server
microk8s enable kwasm
#
# Install Envoy for Gateway API support
#
microk8s helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.0 -n envoy-gateway-system --create-namespace
microk8s kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
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
# Annotate all nodes so they get the SpinKube operator
# 
microk8s kubectl annotate node --all kwasm.sh/kwasm-node=true
#
# Addition cluster role for Gateway and HTTPRoute support
#
microk8s kubectl apply -f exdns-role-bindings.yaml
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
# Install k83_gateway for external DNS, setting the domain and IP Port
#
microk8s helm repo add k8s_gateway https://k8s-gateway.github.io/k8s_gateway
microk8s helm install exdns --namespace infrastructure \
  --set domain=k8s.koeppster.lan,service.type=LoadBalancer,service.loadBalancerIP=192.168.1.245 \
  --set "watchedResources={Ingress,Service,HTTPRoute,Gateway}" \
  k8s_gateway/k8s-gateway
#
# Create the docker images used
#
docker build -t localhost:32000/awsecr --push -f awsecr.Dockerfile .
docker build -t localhost:32000/awsdns --push -f awsdns.Dockerfile .
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
# Label namespaces so they get the aws ecr secrets 
#
kubectl label namespace --overwrite default koeppster.net\/aws_enabled=true
kubectl label namespace --overwrite infrastructure koeppster.net\/aws_enabled=true
#
# Create other resources 
#
envsubst < create-aws-credentials.yaml | kubectl apply -f -
envsubst < create-awsdns-updater.yaml | kubectl apply -f -
envsubst < aws-ecr-role-and-cron.yaml | kubectl apply -f -
envsubst < create-storage-class.yaml | kubectl apply -f -
envsubst < postgres-storage-class.yaml | kubectl apply -f -
envsubst < create-cert-issuer.yaml | kubectl apply -f -
envsubst < create-gateway-cert.yaml | kubectl apply -f -
#
# Patch to ensure fixed IP address for Envoy Gateway LoadBalancer
#
kubectl apply -f envoy-proxy-patch.yaml
kubectl apply -f create-gateways.yaml
