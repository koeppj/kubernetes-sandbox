#!/bin/bash

set -euo pipefail

BACKUP_DIR="${1:-$HOME/microk8s-backups}"
TIMESTAMP=$(date +%F_%H-%M-%S)
BACKUP_NAME="microk8s-backup-${TIMESTAMP}.tar.gz"
FULL_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

echo "📁 Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

TMP_DIR=$(mktemp -d)
echo "📦 Creating temporary staging area: $TMP_DIR"

# Define which relative paths to attempt to back up
PATHS_TO_BACKUP=(
  "args"
  "certs"
  "manifests"
  "var/lock"
)

# Copy optional directories if they exist
for path in "${PATHS_TO_BACKUP[@]}"; do
  FULL="/var/snap/microk8s/current/$path"
  if [[ -d "$FULL" ]]; then
    echo "🗃️  Copying $path"
    mkdir -p "$TMP_DIR/$path"
    sudo cp -a "$FULL/." "$TMP_DIR/$path/"
  else
    echo "⚠️  Skipping missing path: $path"
  fi
done

# Stop etcd and copy backend state
echo "🔄 Stopping etcd daemon..."
sudo systemctl stop snap.microk8s.daemon-etcd

BACKEND_PATH="/var/snap/microk8s/current/var/kubernetes/backend"
if [[ -d "$BACKEND_PATH" ]]; then
  echo "🗃️  Copying etcd backend"
  mkdir -p "$TMP_DIR/var/kubernetes/backend"
  sudo cp -a "$BACKEND_PATH/." "$TMP_DIR/var/kubernetes/backend/" || echo "⚠️  Some backend files changed during copy, partial backup saved."
else
  echo "❌ Missing backend etcd path: $BACKEND_PATH"
fi

echo "🚀 Restarting etcd daemon..."
sudo systemctl start snap.microk8s.daemon-etcd

# Create the final backup tarball
echo "🗜️  Creating backup archive: $FULL_PATH"
sudo tar czf "$FULL_PATH" -C "$TMP_DIR" .

# Clean up
echo "🧹 Cleaning up temporary files"
sudo rm -rf "$TMP_DIR"

echo "✅ Backup complete: $FULL_PATH"
