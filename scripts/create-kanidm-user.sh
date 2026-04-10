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

# Parse arguments: support --role / -r flag
ROLE="user"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--role)
      ROLE="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

USERNAME="${1:-}"
DISPLAY_NAME="${2:-}"

if [ -z "$USERNAME" ] || [ -z "$DISPLAY_NAME" ]; then
  echo "Usage: $0 [--role admin|user] <username> <\"Display Name\">"
  echo ""
  echo "Roles:"
  echo "  admin  — Global Admin: access to ALL applications (infra + user stacks)"
  echo "  user   — Regular User: access to user-assigned stacks only (moodle, n8n, notes)"
  echo ""
  echo "Examples:"
  echo "  $0 --role admin geoadmin \"Global Admin\""
  echo "  $0 --role user jdoe \"John Doe\""
  echo "  $0 jdoe \"John Doe\"              # defaults to 'user' role"
  exit 1
fi

if [[ "$ROLE" != "admin" && "$ROLE" != "user" ]]; then
  echo "❌ Error: Invalid role '$ROLE'. Must be 'admin' or 'user'."
  exit 1
fi

KANIDM_GROUP="brain_${ROLE}s"

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

    echo \">>> Adding ${USERNAME} to group ${KANIDM_GROUP}...\"
    kanidm group add-members ${KANIDM_GROUP} ${USERNAME} -H ${KANIDM_URL} -D idm_admin -C /tmp/ca.crt 2>&1 || true

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
    echo "🔗 Role:   ${ROLE} (group: ${KANIDM_GROUP})"
    echo "🔗 Kanidm Credential Reset URL (valid for 1 hour):"
    echo "   $RESET_URL"
    echo "================================================="
    if [[ "$ROLE" == "admin" ]]; then
        echo "This admin user has access to ALL applications."
    else
        echo "This user has access to user-assigned stacks (moodle, n8n, notes)."
    fi
    echo "Share this URL with the user to set their password."
else
    echo "⚠️  User '${USERNAME}' was created but could not generate a reset token."
    echo "   You can manually create one:"
    echo "   kanidm person credential create-reset-token ${USERNAME} -H ${KANIDM_URL} -D idm_admin"
    exit 1
fi
