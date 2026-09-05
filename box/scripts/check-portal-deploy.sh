#!/bin/bash

set -euo pipefail

microk8s kubectl -n box rollout status deployment/box-portal
microk8s kubectl -n box get deployment,service,pods
microk8s kubectl -n box get httproute box-portal-route box-portal-redirect
microk8s kubectl -n box logs deployment/box-portal --tail=50
