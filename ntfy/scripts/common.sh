#!/usr/bin/env bash
# Shared by deploy.sh and check-deploy.sh; sourcing performs no cluster changes.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export manifests_dir="${SCRIPT_DIR}/../manifests"

prepare_environment() {
  if [[ ! -f "${SCRIPT_DIR}/../.env" ]]; then
    echo 'Missing ntfy/.env. Copy ntfy/.env.sample to ntfy/.env and fill in the credentials.' >&2
    return 1
  fi
  source "${SCRIPT_DIR}/../.env"
  local variable
  for variable in NTFY_AUTH_USERS NTFY_AUTH_ACCESS NTFY_AUTH_TOKENS; do
    if [[ -z "${!variable:-}" || "${!variable}" == *'<'* ]]; then
      echo "Set ${variable} in ntfy/.env; empty values and sample placeholders are not accepted." >&2
      return 1
    fi
  done
  export ntfy_auth_users_encoded ntfy_auth_access_encoded ntfy_auth_tokens_encoded
  ntfy_auth_users_encoded=$(printf '%s' "$NTFY_AUTH_USERS" | base64 -w 0)
  ntfy_auth_access_encoded=$(printf '%s' "$NTFY_AUTH_ACCESS" | base64 -w 0)
  ntfy_auth_tokens_encoded=$(printf '%s' "$NTFY_AUTH_TOKENS" | base64 -w 0)
  export ntfy_config_checksum ntfy_secret_checksum
  ntfy_config_checksum=$(sha256sum "${manifests_dir}/ntfy-configmap.yaml" | cut -d ' ' -f 1)
  ntfy_secret_checksum=$(render_manifest ntfy-secret.yaml | sha256sum | cut -d ' ' -f 1)
}

render_manifest() {
  case "$1" in
    ntfy-secret.yaml)
      envsubst '${ntfy_auth_users_encoded} ${ntfy_auth_access_encoded} ${ntfy_auth_tokens_encoded}' < "${manifests_dir}/$1"
      ;;
    ntfy-statefulset.yaml)
      envsubst '${ntfy_config_checksum} ${ntfy_secret_checksum}' < "${manifests_dir}/$1"
      ;;
    *) cat "${manifests_dir}/$1" ;;
  esac
}
