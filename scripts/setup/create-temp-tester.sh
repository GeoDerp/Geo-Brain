#!/usr/bin/env bash
# create-temp-tester.sh: Creates a temporary Kanidm user for OIDC validation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

USERNAME="${1:-temp-tester}"
DISPLAY_NAME="OIDC Automated Tester"
DOMAIN="${DOMAIN:-brain.home.lan}"
KANIDM_URL="https://kanidm.${DOMAIN}"
ADMIN_PASS="${KANIDM_ADMIN_PASSWORD:?KANIDM_ADMIN_PASSWORD must be set in .env}"

SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

if [[ -n "${REMOTE_HOST:-}" ]]; then
    REMOTE_CMD=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -i "${SSH_KEY}" -p "${SSH_PORT:-22}" "${REMOTE_USER}@${REMOTE_HOST}")
else
    REMOTE_CMD=()
fi

run_remote() {
    if [[ ${#REMOTE_CMD[@]} -gt 0 ]]; then
        "${REMOTE_CMD[@]}" "$@"
    else
        eval "$@"
    fi
}

echo ">>> Creating temp user '${USERNAME}' for automated testing..."

# Create the user first via API tools
run_remote "podman run -i --rm --network host \
  --env ADMIN_PASS='${ADMIN_PASS}' \
  docker.io/kanidm/tools:1.9.2 sh -c '
    kanidm login -H ${KANIDM_URL} -D idm_admin --accept-invalid-certs --password "\${ADMIN_PASS}"
    kanidm person delete ${USERNAME} -H ${KANIDM_URL} -D idm_admin --accept-invalid-certs 2>/dev/null || true
    kanidm person create ${USERNAME} \"${DISPLAY_NAME}\" -H ${KANIDM_URL} -D idm_admin --accept-invalid-certs
    kanidm group add-members brain_admins ${USERNAME} -H ${KANIDM_URL} -D idm_admin --accept-invalid-certs
    kanidm group add-members brain_users ${USERNAME} -H ${KANIDM_URL} -D idm_admin --accept-invalid-certs
  '"

# Use recover-account to set a known-ish (random but captured) password
echo ">>> Setting password for '${USERNAME}' via recover-account..."
REC_OUT=$(run_remote "podman exec kanidm /sbin/kanidmd recover-account -c /data/server.toml ${USERNAME} 2>&1")
NEW_PASS=$(echo "$REC_OUT" | grep "new_password" | grep -o '"[^"]*"' | tr -d '"')

if [[ -z "$NEW_PASS" ]]; then
    echo "❌ Failed to capture new password for ${USERNAME}"
    echo "$REC_OUT"
    exit 1
fi

echo "✅ Temp user '${USERNAME}' created."
echo "✅ PASSWORD: ${NEW_PASS}"

# Save to a temporary file for tests to consume
echo "TEST_USERNAME=${USERNAME}" > "${REPO_ROOT}/tests/.test_creds"
echo "TEST_PASSWORD=${NEW_PASS}" >> "${REPO_ROOT}/tests/.test_creds"
chmod 600 "${REPO_ROOT}/tests/.test_creds"
