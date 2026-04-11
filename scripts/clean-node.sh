#!/usr/bin/env bash
# =============================================================================
# clean-node.sh - Completely wipes the remote node of Geo-Brain data
#
# Usage: ./scripts/clean-node.sh [--yes] [--images]
#
#   --yes      Skip the interactive confirmation prompt (for automation).
#   --images   Also prune all container images on the remote node.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

REMOTE_HOST="${REMOTE_HOST:-brain.home.lan}"
REMOTE_USER="${REMOTE_USER:-admin}"
SSH_PORT="${SSH_PORT:-22}"
DATA_DIR="${DATA_DIR:-/var/Geo-Brain}"
DATA_DIR="${DATA_DIR/#\~/$HOME}"
REMOTE_BASE="${REMOTE_PROJECT_DIR:-Geo-Brain}"

# Safety guard: refuse to operate if DATA_DIR is empty, root, or a system path
if [[ -z "$DATA_DIR" || "$DATA_DIR" == "/" || "$DATA_DIR" == "/var" || "$DATA_DIR" == "/home" ]]; then
    echo "❌ FATAL: DATA_DIR is empty or a system root path ('$DATA_DIR'). Refusing to wipe."
    exit 1
fi

SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

# --- Argument Parsing ---
AUTO_YES=0
PRUNE_IMAGES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)    AUTO_YES=1; shift ;;
        --images) PRUNE_IMAGES=1; shift ;;
        -h|--help)
            awk '/^# Usage:/,/^# ===/' "$0" | grep -v '^# ===' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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

SSH_CMD=(ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" "${REMOTE_USER}@${REMOTE_HOST}")

IMAGE_WARNING=""
if [[ "$PRUNE_IMAGES" -eq 1 ]]; then
    IMAGE_WARNING=" and ALL container images"
fi

echo "⚠️  WARNING: This will completely wipe all containers, volumes${IMAGE_WARNING}, and data in $DATA_DIR on $REMOTE_HOST!"

if [[ "$AUTO_YES" -eq 0 ]]; then
    read -rp "Are you sure you want to proceed? (Type 'yes' to continue): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
fi

"${SSH_CMD[@]}" bash -s -- "$DATA_DIR" "$REMOTE_BASE" "$PRUNE_IMAGES" << 'REMOTE_CLEAN'
DATA_DIR="$1"
REMOTE_BASE="$2"
PRUNE_IMAGES="$3"

  echo '>>> Stopping and removing all containers...'
  podman stop --all 2>/dev/null || true
  podman rm --all --force 2>/dev/null || true

  echo '>>> Pruning networks and volumes...'
  podman network prune -f 2>/dev/null || true
  podman volume prune -a -f 2>/dev/null || true

  if [[ "$PRUNE_IMAGES" -eq 1 ]]; then
    echo '>>> Pruning all container images...'
    podman image prune -a -f 2>/dev/null || true
  fi

  echo ">>> Removing project files in $DATA_DIR..."
  sudo rm -rf "$DATA_DIR" || podman unshare rm -rf "$DATA_DIR" || true

  echo ">>> Removing remote project directory (~/${REMOTE_BASE})..."
  rm -rf ~/"${REMOTE_BASE}" || true
REMOTE_CLEAN

# Clean up locally generated Traefik configs so the next deploy starts fresh
echo ">>> Cleaning up locally generated Traefik configs..."
rm -f "$SCRIPT_DIR/stacks/traefik/config/dynamic"/gen_*.yml 2>/dev/null || true

echo "✅ Clean complete."
