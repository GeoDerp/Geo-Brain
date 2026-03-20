#!/usr/bin/env bash
# =============================================================================
# clean-node.sh - Completely wipes the remote node of Geo-Brain data
# =============================================================================
set -euo pipefail

if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

REMOTE_HOST="${REMOTE_HOST:-brain.home.lan}"
REMOTE_USER="${REMOTE_USER:-admin}"
DATA_DIR="${DATA_DIR:-/var/Geo-Brain}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"

echo "⚠️  WARNING: This will completely wipe all containers, volumes, and data in $DATA_DIR on $REMOTE_HOST!"
read -p "Are you sure you want to proceed? (Type 'yes' to continue): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" "
  echo '>>> Stopping and removing all containers...'
  podman stop --all || true
  podman rm --all --force || true
  
  echo '>>> Pruning networks and volumes...'
  podman network prune -f || true
  podman volume prune -f || true

  echo '>>> Removing project files in $DATA_DIR...'
  sudo rm -rf $DATA_DIR || podman unshare rm -rf $DATA_DIR || true
  rm -rf ~/Geo-Brain || true
"

echo "✅ Clean complete."
