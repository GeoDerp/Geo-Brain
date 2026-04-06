#!/usr/bin/env bash
# =============================================================================
# create-kanidm-user.sh
# Creates a new person (user) account in Kanidm using the tools container
# and generates a secure initial password.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

USERNAME="${1:-}"
DISPLAY_NAME="${2:-}"

if [ -z "$USERNAME" ] || [ -z "$DISPLAY_NAME" ]; then
  echo "Usage: $0 <username> <\"Display Name\">"
  echo "Example: $0 admin \"Global Admin\""
  exit 1
fi

if [[ -n "${REMOTE_HOST:-}" ]]; then
    PODMAN="podman --connection ${PODMAN_CONNECTION:-homelab}"
else
    PODMAN="podman"
fi

KANIDM_URL="https://kanidm.${DOMAIN:-example.local}"

read -s -p "Enter idm_admin password (recovery password from setup-brain.sh): " PASSWORD
echo ""

echo ">>> Creating Kanidm user '${USERNAME}' via kanidm/tools container..."

CA_CERT=$(cat "$REPO_ROOT/certs/ca.crt")

$PODMAN run -i --rm --network host \
  --env KANIDM_PASSWORD="$PASSWORD" \
  docker.io/kanidm/tools:1.9.2 sh -c "
    cat << 'CAEOF' > /tmp/ca.crt
$CA_CERT
CAEOF
    kanidm login -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt >/dev/null 2>&1
    kanidm person create ${USERNAME} '${DISPLAY_NAME}' -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt >/dev/null 2>&1 || echo '⚠️ User ${USERNAME} may already exist.'
"

echo ">>> Generating secure initial password for '${USERNAME}'..."
# Extract the container name dynamically, fallback to 'kanidm'
KANIDM_CONTAINER=$($PODMAN ps -a --format "{{.Names}}" | grep kanidm | head -n 1 || echo "kanidm")

NEW_PASSWORD=$($PODMAN exec "$KANIDM_CONTAINER" /sbin/kanidmd recover-account -c /data/server.toml "$USERNAME" 2>&1 | grep new_password | grep -o '"[^"]*"' | tr -d '"' || true)

if [[ -n "$NEW_PASSWORD" ]]; then
    echo "✅ User ${USERNAME} created successfully."
    echo "================================================="
    echo "🔑 Initial Password: $NEW_PASSWORD"
    echo "================================================="
    echo "You can now use this account to log into all SSO-protected services."
    echo "To change your password, log into the Kanidm Web UI as '${USERNAME}': ${KANIDM_URL}"
else
    echo "❌ Failed to generate initial password. Check kanidm container logs."
    exit 1
fi
