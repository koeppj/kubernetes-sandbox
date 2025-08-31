#!/bin/bash
if [ -f ~/.bash_aliases ]; then
    shopt -s expand_aliases
    source ~/.bash_aliases
fi

microk8s kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.runtime-class.yaml
microk8s kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.crds.yaml
microk8s helm repo add kwasm http://kwasm.sh/kwasm-operator/
microk8s helm install kwasm-operator kwasm/kwasm-operator --namespace kwasm --create-namespace --set kwasmOperator.installerImage=ghcr.io/spinframework/containerd-shim-spin/node-installer:v0.21.0
microk8s kubectl annotate node --all kwasm.sh/kwasm-node=true
microk8s helm install spin-operator --namespace spin-operator --create-namespace --version 0.6.1 --wait oci://ghcr.io/spinframework/charts/spin-operator
microk8s kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.shim-executor.yaml
