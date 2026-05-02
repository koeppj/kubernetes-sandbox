#!/bin/bash

set -euo pipefail

microk8s kubectl -n box-enterprise-quarantine scale statefulset/box-quarantine-listener --replicas=1
