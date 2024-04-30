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
# Environment Variable Setups
#
export aws_access_key_id=$(sed -rn '/aws_access_key_id = /p' ~/.aws/credentials | cut -d '=' -f2 | tr -d '[:space:]')
export aws_access_key_id_encoded=$(sed -rn '/aws_access_key_id = /p' ~/.aws/credentials | cut -d '=' -f2 | tr -d '[:space:]' | base64)
export aws_secret_access_key=$(sed -rn '/aws_secret_access_key = /p' ~/.aws/credentials | cut -d '=' -f2 | tr -d '[:space:]')
export aws_secret_access_key_encoded=$(sed -rn '/aws_secret_access_key = /p' ~/.aws/credentials | cut -d '=' -f2 | tr -d '[:space:]' | base64)
export aws_default_region=$(sed -rn '/region = /p' ~/.aws/config | cut -d '=' -f2 | tr -d '[:space:]')
export aws_default_region_encoded=$(sed -rn '/region = /p' ~/.aws/config | cut -d '=' -f2 | tr -d '[:space:]' | base64)
export kube_host_ip=$(curl -s -4 icanhazip.com > /dev/null)
#
# Enable plugins
#
microk8s enable community
microk8s enable registry
microk8s enable cert-manager
microk8s enable istio
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
# Create the docker images used
#
docker build -t localhost:32000/awsecr --push -f awsecr.Dockerfile .
docker build -t localhost:32000/awsdns --push -f awsdns.Dockerfile .
#
# Create/Update namespace
#
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: 
    name: infrastructure
EOF
envsubst < create-aws-credentials.yaml | kubectl apply -f -
envsubst < create-awsdns-updater.yaml | kubectl apply -f -
microk8s kubectl apply -f aws-ecr-role-and-cron.yaml
microk8s kubectl apply -f create-storage-class.yaml
envsubst < create-cert-issuer.yaml | kubectl apply -f -