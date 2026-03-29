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
DATA_DIR="${DATA_DIR/#\~/$HOME}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

_SCRIPT_STARTED_AGENT=0
cleanup() {
    if [[ "$_SCRIPT_STARTED_AGENT" -eq 1 && -n "${SSH_AGENT_PID:-}" ]]; then
        echo ">>> Cleaning up temporary ssh-agent (PID: $SSH_AGENT_PID)..."
        kill "$SSH_AGENT_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ -n "$SSH_KEY" ]]; then
    if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l &>/dev/null; then
        echo ">>> Starting temporary ssh-agent..."
        eval "$(ssh-agent -s)" >/dev/null
        _SCRIPT_STARTED_AGENT=1
    fi
    key_fp=$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')
    if ! ssh-add -l 2>/dev/null | grep -qF "$key_fp"; then
        echo ">>> Adding SSH key to agent (enter passphrase if prompted)..."
        ssh-add "$SSH_KEY"
    fi
fi

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
