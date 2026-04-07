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
  echo "Example: $0 geoadmin \"Global Admin\""
  exit 1
fi

# Kanidm reserves 'admin' and 'idm_admin' as built-in service accounts.
# Creating a person with these names silently fails, and recover-account
# would reset the service account instead — causing 'nomatchingentries' in the UI.
RESERVED_NAMES="admin idm_admin"
for reserved in $RESERVED_NAMES; do
  if [[ "$USERNAME" == "$reserved" ]]; then
    echo "❌ Error: '$reserved' is a built-in Kanidm service account and cannot be used as a person name."
    echo "   Choose a different username, e.g.: $0 geoadmin \"Global Admin\""
    exit 1
  fi
done

KANIDM_URL="https://kanidm.${DOMAIN:-example.local}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

# Build the remote execution command (SSH for reliability; podman remote hangs on exec/ps)
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

read -s -p "Enter idm_admin password (recovery password from setup-brain.sh): " PASSWORD
echo ""

# Validate inputs don't contain shell-unsafe characters (prevent injection via SSH)
for var_name in USERNAME DISPLAY_NAME PASSWORD; do
    if [[ "${!var_name}" =~ [\'\`\$\;\|] ]]; then
        echo "❌ Error: ${var_name} contains unsafe characters."
        exit 1
    fi
done

# Generate a strong random POSIX password for LDAP/Authelia login
# (Kanidm LDAP bind uses the UNIX/POSIX password, NOT the primary credential)
POSIX_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)

echo ">>> Creating Kanidm user '${USERNAME}' via kanidm/tools container..."

CA_CERT=$(cat "$REPO_ROOT/certs/ca.crt")

# All operations use the kanidm CLI tools container via the Kanidm API.
# (podman exec into the kanidm server container hangs due to the minimal image.)
SETUP_OUTPUT=$(run_remote "podman run -i --rm --network host \
  --env KANIDM_PASSWORD='${PASSWORD}' \
  docker.io/kanidm/tools:1.9.2 sh -c '
    cat << CAEOF > /tmp/ca.crt
${CA_CERT}
CAEOF
    echo \">>> Logging in as idm_admin...\"
    if ! kanidm login -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt 2>&1; then
        echo \"KANIDM_LOGIN_FAILED\"
        exit 1
    fi

    echo \">>> Creating person ${USERNAME}...\"
    kanidm person create ${USERNAME} \"${DISPLAY_NAME}\" -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt 2>&1 || true

    echo \">>> Enabling POSIX attributes (required for LDAP bind via Authelia)...\"
    kanidm person posix set ${USERNAME} -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt 2>&1 || true

    echo \">>> Setting POSIX password (used for Authelia/SSO login)...\"
    TOKEN_JSON=\$(cat /root/.cache/kanidm_tokens 2>/dev/null)
    API_TOKEN=\$(echo \"\$TOKEN_JSON\" | grep -oP \"idm_admin@[^\\\"]+\\\":\\s*\\\"\\K[^\\\"]+\")
    POSIX_HTTP=\$(curl -sk -o /dev/null -w \"%{http_code}\" --cacert /tmp/ca.crt -X PUT \
      -H \"Authorization: Bearer \$API_TOKEN\" \
      -H \"Content-Type: application/json\" \
      -d \"{\\\"value\\\":\\\"${POSIX_PASSWORD}\\\"}\" \
      ${KANIDM_URL}/v1/person/${USERNAME}/_unix/_credential)
    if [ \"\$POSIX_HTTP\" = \"200\" ]; then
        echo \"KANIDM_POSIX_PW_OK\"
    else
        echo \"KANIDM_POSIX_PW_FAILED (HTTP \$POSIX_HTTP)\"
    fi

    echo \">>> Verifying account exists...\"
    if ! kanidm person get ${USERNAME} -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt >/dev/null 2>&1; then
        echo \"KANIDM_PERSON_MISSING\"
        exit 1
    fi
    echo \"KANIDM_PERSON_OK\"

    echo \">>> Generating credential reset token...\"
    RESET_TOKEN=\$(kanidm person credential create-reset-token ${USERNAME} 3600 -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt 2>&1)
    TOKEN_VALUE=\$(echo \"\$RESET_TOKEN\" | grep -oP \"\\?token=\\K[^ ]+\" | head -1)
    if [ -n \"\$TOKEN_VALUE\" ]; then
        echo \"KANIDM_RESET_TOKEN=\$TOKEN_VALUE\"
    else
        echo \"KANIDM_TOKEN_FAILED\"
        echo \"\$RESET_TOKEN\"
    fi
  '" 2>&1)

echo "$SETUP_OUTPUT" | grep -v "^KANIDM_"

if echo "$SETUP_OUTPUT" | grep -q "KANIDM_LOGIN_FAILED"; then
    echo "❌ Failed to authenticate as idm_admin. Check your password."
    exit 1
fi

if echo "$SETUP_OUTPUT" | grep -q "KANIDM_PERSON_MISSING"; then
    echo "❌ Person '${USERNAME}' could not be created. Check kanidm container logs."
    exit 1
fi

if echo "$SETUP_OUTPUT" | grep -q "KANIDM_POSIX_PW_FAILED"; then
    echo "⚠️  POSIX password could not be set via API. Authelia/SSO login will not work."
    echo "   You may need to set it manually via the Kanidm API."
fi

if echo "$SETUP_OUTPUT" | grep -q "KANIDM_TOKEN_FAILED"; then
    echo "❌ Failed to generate credential reset token."
    exit 1
fi

# Extract the reset token and build the credential reset URL
RESET_TOKEN_LINE=$(echo "$SETUP_OUTPUT" | grep "KANIDM_RESET_TOKEN=" | head -1)
TOKEN="${RESET_TOKEN_LINE#KANIDM_RESET_TOKEN=}"

if [[ -n "$TOKEN" ]]; then
    RESET_URL="${KANIDM_URL}/ui/reset?token=${TOKEN}"
    echo "✅ User '${USERNAME}' created successfully."
    echo "================================================="
    echo "🔑 Authelia/SSO Login Password (POSIX):"
    echo "   ${POSIX_PASSWORD}"
    echo ""
    echo "🔗 Kanidm Web UI Reset URL (valid for 1 hour):"
    echo "   $RESET_URL"
    echo "================================================="
    echo "Use the POSIX password above to log into Authelia-protected services."
    echo "Use the reset URL to set a password for the Kanidm web UI."
else
    echo "⚠️  User '${USERNAME}' was created but could not generate a reset token."
    echo "   You can manually create one:"
    echo "   kanidm person credential create-reset-token ${USERNAME} -H ${KANIDM_URL} -D idm_admin"
    exit 1
fi
