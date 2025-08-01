#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "❌ Usage: $0 /path/to/microk8s-backup-YYYY-MM-DD_HH-MM-SS.tar.gz"
  exit 1
fi

BACKUP_FILE="$1"
SNAP_PATH="/var/snap/microk8s/current"
TMP_RESTORE=$(mktemp -d)

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "❌ Backup file does not exist: $BACKUP_FILE"
  exit 2
fi

echo "⚠️  This will overwrite parts of your current MicroK8s state."
read -p "Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "❌ Aborted."
  exit 3
fi

echo "📦 Extracting backup to temporary location: $TMP_RESTORE"
sudo tar xzf "$BACKUP_FILE" -C "$TMP_RESTORE"

echo "🔻 Stopping MicroK8s services..."
sudo systemctl stop snap.microk8s.daemon-*

# Define which directories to restore
RESTORE_PATHS=(
  "args"
  "certs"
  "manifests"
  "var/lock"
  "var/kubernetes/backend"
)

for path in "${RESTORE_PATHS[@]}"; do
  SRC="$TMP_RESTORE/$path"
  DEST="$SNAP_PATH/$path"

  if [[ -d "$SRC" ]]; then
    echo "♻️  Restoring $path"
    sudo mkdir -p "$DEST"
    sudo cp -a "$SRC/." "$DEST/"
  else
    echo "⚠️  Skipping missing restore path: $path"
  fi
done

echo "🚀 Starting MicroK8s services..."
sudo systemctl start snap.microk8s.daemon-apiserver
sudo systemctl start snap.microk8s.daemon-controller-manager
sudo systemctl start snap.microk8s.daemon-etcd
sudo systemctl start snap.microk8s.daemon-kubelet
sudo systemctl start snap.microk8s.daemon-proxy
sudo systemctl start snap.microk8s.daemon-flanneld

echo "🧹 Cleaning up temporary files..."
sudo rm -rf "$TMP_RESTORE"

echo "✅ Restore complete. You can check cluster status with:"
echo "   microk8s status --wait-ready"
