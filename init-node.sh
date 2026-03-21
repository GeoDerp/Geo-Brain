#!/usr/bin/env bash
# init-node.sh: Provision a remote homelab node via Ansible.
# Usage: ./init-node.sh [--host IP] [--user USER] [--key PATH] [--port PORT] [--yes]
#
# Thin wrapper that handles SSH agent setup, argument parsing, and pre-flight
# checks, then delegates provisioning to ansible/init-node.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/ansible/init-node.yml"

# --- Configuration ---
REMOTE_HOST=""
REMOTE_USER=""
SSH_KEY=""
SSH_PORT="22"
AUTO_YES=""

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --host) REMOTE_HOST="$2"; shift 2 ;;
        --user) REMOTE_USER="$2"; shift 2 ;;
        --key)  SSH_KEY="$2"; shift 2 ;;
        --port) SSH_PORT="$2"; shift 2 ;;
        --yes)  AUTO_YES=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--host IP] [--user USER] [--key PATH] [--port PORT] [--yes]"
            echo ""
            echo "Provisions a remote homelab node and configures local podman-remote access."
            echo "Omitted options will be prompted interactively by the Ansible playbook."
            echo ""
            echo "  --yes    Skip confirmation prompts for major changes"
            exit 0 ;;
        *) echo "[ERROR] Unknown option: $1"; exit 1 ;;
    esac
done

# --- Pre-flight: Check Ansible ---
if ! command -v ansible-playbook &>/dev/null; then
    echo "[ERROR] ansible-playbook not found. Install ansible-core:"
    echo "    pip install ansible-core"
    echo "    # or: dnf install ansible-core"
    exit 1
fi

if [[ ! -f "$PLAYBOOK" ]]; then
    echo "[ERROR] Playbook not found: $PLAYBOOK"
    exit 1
fi

# --- Expand SSH key tilde early (for agent loading) ---
if [[ -n "$SSH_KEY" ]]; then
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    if [[ ! -f "$SSH_KEY" ]]; then
        echo "[ERROR] SSH key not found: $SSH_KEY"
        exit 1
    fi
fi

_SCRIPT_STARTED_AGENT=0
cleanup() {
    if [[ "$_SCRIPT_STARTED_AGENT" -eq 1 && -n "${SSH_AGENT_PID:-}" ]]; then
        echo ">>> Cleaning up temporary ssh-agent (PID: $SSH_AGENT_PID)..."
        kill "$SSH_AGENT_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- SSH Agent / Passphrase Handling ---
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

# --- Build Ansible Extra Vars ---
EXTRA_VARS=()
[[ -n "$REMOTE_HOST" ]] && EXTRA_VARS+=(-e "cli_remote_host=$REMOTE_HOST")
[[ -n "$REMOTE_USER" ]] && EXTRA_VARS+=(-e "cli_target_user=$REMOTE_USER")
[[ -n "$SSH_KEY" ]]     && EXTRA_VARS+=(-e "cli_ssh_key_path=$SSH_KEY")
[[ "$SSH_PORT" != "22" ]] && EXTRA_VARS+=(-e "cli_ssh_port=$SSH_PORT")
[[ -n "$AUTO_YES" ]]    && EXTRA_VARS+=(-e "auto_yes=true")

# --- Run Playbook ---
echo ">>> Geo-Brain: Remote Node Initialization"
echo "    Playbook: ${PLAYBOOK}"
[[ -n "$REMOTE_HOST" ]] && echo "    Target:   ${REMOTE_USER:-$USER}@${REMOTE_HOST}:${SSH_PORT}"
echo ""

exec ansible-playbook "$PLAYBOOK" ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"}
