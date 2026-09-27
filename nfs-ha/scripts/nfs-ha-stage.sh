#!/usr/bin/env bash
# Writes private offline artifacts only. Never contacts the live CIB.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# != 1 ]]; then
    echo 'Usage: nfs-ha-stage.sh NEW_OUTPUT_DIRECTORY' >&2
    exit 2
fi
set -a
# shellcheck disable=SC1090
source "${NFS_HA_ENV:-$SCRIPT_DIR/../.env}"
set +a
umask 077
exec python3 "$SCRIPT_DIR/nfs-ha-render.py" "$@"
