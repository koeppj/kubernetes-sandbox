#!/bin/bash

set -euo pipefail

#
# Get project root.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source "$SCRIPT_DIR/../.env"
export manifests_dir="$SCRIPT_DIR/../manifests"

export postgres_user_encoded="$(printf '%s' "$POSTGRES_USER" | base64 | tr -d '\n')"
export postgres_password_encoded="$(printf '%s' "$POSTGRES_PASSWORD" | base64 | tr -d '\n')"
export postgres_db_encoded="$(printf '%s' "$POSTGRES_DB" | base64 | tr -d '\n')"
export postgres_non_root_user_encoded="$(printf '%s' "$POSTGRES_NON_ROOT_USER" | base64 | tr -d '\n')"
export postgres_non_root_password_encoded="$(printf '%s' "$POSTGRES_NON_ROOT_PASSWORD" | base64 | tr -d '\n')"

envsubst < "$manifests_dir/$1.yaml"
