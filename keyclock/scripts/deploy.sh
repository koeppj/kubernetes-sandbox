#!/bin/bash

#
# Get project root.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source $SCRIPT_DIR/../.env
export manifests_dir=$SCRIPT_DIR/../manifests
export values_dir=$SCRIPT_DIR/../values

export postgres_user_encoded=$(echo ${POSTGRES_USER} | tr -d '[:space:]' | base64)
export postgres_password_encoded=$(echo ${POSTGRES_PASSWORD} | tr -d '[:space:]' | base64)
export postgres_db_encoded=$(echo ${POSTGRES_DB} | tr -d '[:space:]' | base64)
export postgres_non_root_user_encoded=$(echo ${POSTGRES_NON_ROOT_USER} | tr -d '[:space:]' | base64)
export postgres_non_root_password_encoded=$(echo ${POSTGRES_NON_ROOT_PASSWORD} | tr -d '[:space:]' | base64)
export keycloak_admin_encoded=$(echo ${KEYCLOAK_ADMIN} | tr -d '[:space:]' | base64)
export keycloak_admin_password_encoded=$(echo ${KEYCLOAK_ADMIN_PASSWORD} | tr -d '[:space:]' | base64)
export DOLLAR='$'

envsubst < ${manifests_dir}/namespace.yaml | microk8s kubectl apply -f -
envsubst < ${manifests_dir}/postgres-secret.yaml | microk8s kubectl apply -f -
# DO NOT PRESUB UBST THE FOLLOWING, AS IT CONTAINS ENVIRONMENT VARIABLES TO BE SUBSTED AT RUNTIME
microk8s kubectl apply -f ${manifests_dir}/postgres-configmap.yaml 
envsubst < ${manifests_dir}/postgres-statefulset.yaml | microk8s kubectl apply -f -
envsubst < ${manifests_dir}/keycloak-secret.yaml | microk8s kubectl apply -f -
envsubst < ${manifests_dir}/keycloak-pvc.yaml | microk8s kubectl apply -f -
envsubst < ${manifests_dir}/keycloak-deployment.yaml | microk8s kubectl apply -f -
envsubst < ${manifests_dir}/keycloak-service.yaml | microk8s kubectl apply -f -
envsubst < ${manifests_dir}/keycloak-gateway.yaml | microk8s kubectl apply -f -
