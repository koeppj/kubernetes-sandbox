#!/bin/bash
# 0) Context
set -euo pipefail
if [ -f ~/.bash_aliases ]; then
    shopt -s expand_aliases
    source ~/.bash_aliases
fi

# 1) Nuke the operator workload and namespace
microk8s kubectl -n spin-operator delete deploy spin-operator-controller-manager --ignore-not-found
microk8s kubectl delete svc -n spin-operator spin-operator-controller-manager-metrics-service spin-operator-webhook-service --ignore-not-found
microk8s kubectl delete ns spin-operator --wait=false || true

# 2) Webhook configurations
microk8s kubectl get mutatingwebhookconfigurations -o name | grep -i spin | xargs -r microk8s kubectl delete
microk8s kubectl get validatingwebhookconfigurations -o name | grep -i spin | xargs -r microk8s kubectl delete

# 3) CRDs created by Spin / Spinkube (adjust the grep if needed)
microk8s kubectl get crd -o name | grep -Ei 'spin|spinkube' | xargs -r microk8s kubectl delete

# 4) RuntimeClass
microk8s kubectl get runtimeclass -o name | grep -i spin | xargs -r microk8s kubectl delete

# 5) Cluster-scope RBAC left by the operator
microk8s kubectl get clusterrole -o name | grep -Ei 'spin|spinkube' | xargs -r microk8s kubectl delete
microk8s kubectl get clusterrolebinding -o name | grep -Ei 'spin|spinkube' | xargs -r microk8s kubectl delete

# 6) ServiceAccounts in the old namespace (if it still exists)
microk8s kubectl get sa -n spin-operator -o name 2>/dev/null | xargs -r microk8s kubectl delete

# 7) If the namespace is stuck terminating, clear finalizers
microk8s kubectl patch ns spin-operator -p '{"metadata":{"finalizers":[]}}' --type=merge || true

# 8) Verify
microk8s kubectl get all -A | grep -E 'spin|spinkube' || echo "no spin/spinkube workloads"
microk8s kubectl get crd | grep -Ei 'spin|spinkube' || echo "no spin/spinkube CRDs"
microk8s kubectl get runtimeclass | grep -i spin || echo "no spin runtimeclasses"
microk8s kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations | grep -i spin || echo "no spin webhooks"
microk8s kubectl get clusterrole,clusterrolebinding | grep -Ei 'spin|spinkube' || echo "no spin RBAC"
