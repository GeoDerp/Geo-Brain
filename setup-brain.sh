#!/bin/bash
# @GEMINI.md: Single Source of Truth for this script's mandates.
# setup-brain.sh
# Idempotent rootless Podman setup script for the My-HomeLab environment
# This script configures Quay, Identity (Kanidm), PKI (Step-CA), SOC (DefectDojo/Wazuh), and Proxy.

set -euo pipefail

# --- Configuration & Seed Variables ---
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

# Fallback/Default variables if not in .env
DOMAIN=${DOMAIN:-stig-homelab.local}
ADMIN_PASSWORD=${ADMIN_PASSWORD:?"ADMIN_PASSWORD must be set in .env — generate with: openssl rand -base64 32"}
MAX_RETRIES=15
INITIAL_BACKOFF=2
DATA_DIR=${DATA_DIR:-/var/My-HomeLab}
DATA_DIR="${DATA_DIR/#\~/$HOME}"

echo "Starting My-HomeLab post-deployment rootless bootstrapper..."

# Global state variables
KANIDM_RECOVERY=""
DD_ADMIN_PASSWORD=""

# --- Podman Connection Wrapper ---
PODMAN="podman"
if [[ -n "${REMOTE_HOST:-}" ]]; then
  if podman system connection ls --format '{{.Name}} {{.URI}}' | grep -q "${REMOTE_HOST}"; then
    CONN_NAME=$(podman system connection ls --format '{{.Name}} {{.URI}}' | grep "${REMOTE_HOST}" | awk '{print $1}' | head -n 1)
    PODMAN="podman --connection ${CONN_NAME}"
    echo "🔹 Using remote podman connection: ${CONN_NAME}"
  else
    HOSTNAME_VAL=$(hostname 2>/dev/null || echo "")
    if [[ "$HOSTNAME_VAL" == "$REMOTE_HOST" ]] || [[ "$HOSTNAME_VAL" == "${REMOTE_HOST%%.*}" ]]; then
       echo "🔹 Detected local execution on target node ${REMOTE_HOST}."
    else
       echo "⚠️  No podman connection found for ${REMOTE_HOST}. Attempting local execution."
    fi
  fi
fi

# --- SSH Wrapper ---
# podman remote (--connection) can hang on exec, ps, logs, and kill.
# SSH executes these operations directly on the node for reliability.
SSH_CMD=()
if [[ -n "${REMOTE_HOST:-}" ]] && [[ -n "${SSH_KEY:-}" ]]; then
    _ssh_key="${SSH_KEY/#\~/$HOME}"
    SSH_CMD=(
        ssh
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=120
        -o ServerAliveInterval=10
        -o ServerAliveCountMax=30
        -i "${_ssh_key}"
        -p "${SSH_PORT:-22}"
        "${REMOTE_USER}@${REMOTE_HOST}"
    )
fi

run_on_node() {
    if [[ ${#SSH_CMD[@]} -gt 0 ]]; then
        "${SSH_CMD[@]}" "$@"
    else
        eval "$@"
    fi
}

# --- Helper Functions ---

wait_for_service() {
  local service_name=$1
  local check_command=$2
  local retries=0
  local backoff=$INITIAL_BACKOFF

  echo "Waiting for ${service_name} to be ready..."
  while [ $retries -lt $MAX_RETRIES ]; do
    if eval "$check_command" > /dev/null 2>&1; then
      echo "✅ ${service_name} is ready!"
      return 0
    fi
    echo "⏳ ${service_name} not ready yet. Retrying in ${backoff} seconds..."
    sleep $backoff
    retries=$((retries + 1))
    if [ $backoff -lt 30 ]; then backoff=$((backoff * 2)); fi
  done

  echo "❌ Error: ${service_name} failed to become ready after ${MAX_RETRIES} retries."
  return 1
}

create_secret() {
  local secret_name=$1
  local secret_value=$2

  if $PODMAN secret inspect "${secret_name}" > /dev/null 2>&1; then
    echo "🔹 Secret ${secret_name} already exists. Skipping."
  else
    echo -n "$secret_value" | $PODMAN secret create "$secret_name" -
    echo "✅ Created podman secret: ${secret_name}"
  fi
}

# Persist a secret value into .env, updating empty values from .env-template.
write_env_secret() {
  local var_name="$1"
  local secret_value="$2"

  if [ ! -f .env ]; then
    touch .env
    chmod 600 .env
  fi

  if grep -q "^${var_name}=" .env 2>/dev/null; then
    # Key exists — update in place
    sed -i "s|^${var_name}=.*$|${var_name}=${secret_value}|" .env
  else
    # Key doesn't exist at all — append
    printf '%s=%s\n' "$var_name" "$secret_value" >> .env
  fi
  export "${var_name}=${secret_value}"
}

# Ensure both a Podman secret and a matching .env entry exist.
ensure_secret_and_env() {
  local var_name="$1"
  local secret_name="$2"

  local current_value="${!var_name-}"
  local secret_value
  if [ -n "$current_value" ]; then
    secret_value="$current_value"
  else
    secret_value="$(openssl rand -base64 32)"
  fi

  create_secret "$secret_name" "$secret_value"
  write_env_secret "$var_name" "$secret_value"
}

# --- 1) Quay Initialization ---
init_quay() {
  echo "--- 1) Quay Initialization ---"
  wait_for_service "Quay API" "curl -m 5 -s -k -f https://quay.${DOMAIN}/health/instance" || echo "⚠️ Failed to wait for service, continuing anyway..."
  
  mkdir -p ~/.config/containers
  cat <<EOF > ~/.config/containers/registries.conf
unqualified-search-registries = ["docker.io"]

# Mirror docker.io through Quay proxy cache
[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "quay.${DOMAIN}/docker-io-cache"
insecure = false

# Mirror ghcr.io through Quay proxy cache
[[registry]]
prefix = "ghcr.io"
location = "ghcr.io"

[[registry.mirror]]
location = "quay.${DOMAIN}/ghcr-io-cache"
insecure = false

# Mirror quay.io through Quay proxy cache
[[registry]]
prefix = "quay.io"
location = "quay.io"

[[registry.mirror]]
location = "quay.${DOMAIN}/quay-io-cache"
insecure = false

# Local Quay registry
[[registry]]
location = "quay.${DOMAIN}"
insecure = false
EOF

  # Deploy registries.conf to remote node
  run_on_node "mkdir -p ~/.config/containers"
  scp -i "${_ssh_key:-$HOME/.ssh/id_debug}" -o StrictHostKeyChecking=accept-new \
    ~/.config/containers/registries.conf \
    "${REMOTE_USER}@${REMOTE_HOST}:~/.config/containers/registries.conf"

  echo "✅ Configured Podman registries.conf (local + remote)."

  # Deploy CA cert for Quay TLS trust (self-signed wildcard cert)
  run_on_node "mkdir -p ~/.config/containers/certs.d/quay.${DOMAIN}"
  scp -i "${_ssh_key:-$HOME/.ssh/id_debug}" -o StrictHostKeyChecking=accept-new \
    ./certs/ca.crt \
    "${REMOTE_USER}@${REMOTE_HOST}:~/.config/containers/certs.d/quay.${DOMAIN}/ca.crt"
  echo "✅ Deployed CA cert for Quay registry TLS trust."

  # Login to Quay on remote for proxy cache pulls (anonymous access is disabled)
  run_on_node "podman login --tls-verify=false -u quayadmin -p '${ADMIN_PASSWORD}' quay.${DOMAIN}" || true
  echo "✅ Authenticated Podman to Quay registry."

  # Create proxy cache organizations for upstream registries
  local QUAY_API="https://quay.${DOMAIN}/api/v1"
  local QUAY_TOKEN=""
  local QUAY_COOKIE_JAR="/tmp/quay-session-$$"
  local QUAY_AUTH_MODE=""

  # Initialize admin user if first run (FEATURE_USER_INITIALIZE=true)
  local init_resp
  init_resp=$(curl -m 10 -s -k -X POST "${QUAY_API}/user/initialize" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"quayadmin\", \"password\": \"${ADMIN_PASSWORD}\", \"email\": \"admin@${DOMAIN}\"}" 2>/dev/null) || true
  QUAY_TOKEN=$(echo "$init_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true

  if [[ -n "$QUAY_TOKEN" ]]; then
    QUAY_AUTH_MODE="token"
  else
    # Already initialized — use CSRF-based signin to get session cookie
    local csrf_token
    csrf_token=$(curl -m 10 -s -k -c "$QUAY_COOKIE_JAR" "https://quay.${DOMAIN}/csrf_token" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null) || true
    if [[ -n "$csrf_token" ]]; then
      local signin_resp
      signin_resp=$(curl -m 10 -s -k -b "$QUAY_COOKIE_JAR" -c "$QUAY_COOKIE_JAR" \
        -X POST "https://quay.${DOMAIN}/api/v1/signin" \
        -H "Content-Type: application/json" \
        -H "X-CSRF-Token: ${csrf_token}" \
        -d "{\"username\": \"quayadmin\", \"password\": \"${ADMIN_PASSWORD}\"}" 2>/dev/null) || true
      if echo "$signin_resp" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
        QUAY_AUTH_MODE="session"
      fi
    fi
  fi

  quay_api_call() {
    local method="$1" endpoint="$2" data="$3"
    if [[ "$QUAY_AUTH_MODE" == "token" ]]; then
      curl -m 10 -s -k -X "$method" "${QUAY_API}${endpoint}" \
        -H "Authorization: Bearer ${QUAY_TOKEN}" \
        -H "Content-Type: application/json" \
        ${data:+-d "$data"} 2>/dev/null || true
    elif [[ "$QUAY_AUTH_MODE" == "session" ]]; then
      local csrf
      csrf=$(curl -m 10 -s -k -b "$QUAY_COOKIE_JAR" -c "$QUAY_COOKIE_JAR" \
        "https://quay.${DOMAIN}/csrf_token" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null) || true
      curl -m 10 -s -k -b "$QUAY_COOKIE_JAR" -c "$QUAY_COOKIE_JAR" \
        -X "$method" "${QUAY_API}${endpoint}" \
        -H "Content-Type: application/json" \
        -H "X-CSRF-Token: ${csrf}" \
        ${data:+-d "$data"} 2>/dev/null || true
    fi
  }

  if [[ -n "$QUAY_AUTH_MODE" ]]; then
    local -A UPSTREAM_URLS=(
      ["docker.io"]="docker.io"
      ["ghcr.io"]="ghcr.io"
      ["quay.io"]="quay.io"
    )
    for upstream in "docker.io" "ghcr.io" "quay.io"; do
      local org_name="${upstream//./-}-cache"
      quay_api_call POST "/organization/" \
        "{\"name\": \"${org_name}\", \"email\": \"${org_name}@${DOMAIN}\"}"
      quay_api_call POST "/organization/${org_name}/proxycache" \
        "{\"upstream_registry\": \"${UPSTREAM_URLS[$upstream]}\", \"org_name\": \"${org_name}\", \"expiration_s\": 86400}"
    done
    echo "✅ Configured proxy cache organizations for docker.io, ghcr.io, quay.io."
    rm -f "$QUAY_COOKIE_JAR" 2>/dev/null
  else
    echo "⚠️ Could not authenticate to Quay API. Proxy cache orgs not configured."
  fi
}

# --- 2) PKI (Step-CA & Traefik ACME) ---
setup_pki() {
  echo "--- 2) PKI (Step-CA & Traefik ACME) ---"
  wait_for_service "Step-CA" "curl -m 5 -s -k -f https://ca.${DOMAIN}/health" || echo "⚠️ Failed to wait for service, continuing anyway..."

  echo "Adding ACME provisioner to Step-CA..."
  if run_on_node "podman exec step-ca step ca provisioner list --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt" | grep -q '"name": "acme"'; then
     echo "🔹 ACME provisioner already exists."
  else
     run_on_node "podman exec step-ca step ca provisioner add acme --type ACME --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt"
     run_on_node "podman kill -s SIGHUP step-ca"
     echo "✅ Added ACME provisioner to Step-CA."
  fi

  echo "Injecting Step-CA Root into Traefik..."
  mkdir -p ./stacks/traefik/config/certs
  if run_on_node "podman exec step-ca cat /home/step/certs/root_ca.crt" > ./stacks/traefik/config/certs/root_ca.crt; then
    echo "✅ Traefik now trusts Step-CA."
    # Build combined CA bundle (Step-CA root + self-signed temporary CA)
    cat ./stacks/traefik/config/certs/root_ca.crt ./certs/ca.crt > ./stacks/traefik/config/certs/ca-bundle.crt
    echo "✅ Built combined CA bundle for OAuth2 Proxy."
  else
    echo "⚠️ Failed to inject Step-CA Root into Traefik. Traefik may not trust Step-CA."
  fi
}

# --- 3) Identity (Kanidm) ---
setup_identity() {
  echo "--- 3) Identity (Kanidm) ---"
  wait_for_service "Kanidm" "curl -m 5 -s -k -f https://kanidm.${DOMAIN}/" || echo "⚠️ Failed to wait for service, continuing anyway..."

  echo "Initializing Kanidm Admin Account..."
  KANIDM_RECOVERY=$(run_on_node "timeout 120 podman exec kanidm /sbin/kanidmd recover-account -c /data/server.toml idm_admin 2>&1" | grep new_password | grep -o '"[^"]*"' | tr -d '"' || echo "")
  if [[ -n "$KANIDM_RECOVERY" ]]; then
    echo "✅ Kanidm idm_admin recovery password captured."
    write_env_secret "KANIDM_ADMIN_PASSWORD" "$KANIDM_RECOVERY"
  else
    KANIDM_RECOVERY="Check container logs"
    echo "⚠️ Admin account recovery skipped or password not captured."
  fi
}

# --- 3b) OIDC Client Registration (Kanidm OAuth2 clients + secret sync) ---
# Calls setup-oidc.sh to idempotently create all OAuth2 clients in Kanidm,
# read back the live secrets, and write them to .env. If any secret changed,
# the affected stacks are force-redeployed so the running containers pick up
# the new values.
setup_oidc() {
  # Pass 'force' as first arg to redeploy stacks even if secrets didn't change.
  # This is needed when containers were started before secrets were written to .env.
  local force_redeploy="${1:-false}"
  echo "--- 3b) OIDC Client Registration ---"

  local oidc_script
  oidc_script="$(cd "$(dirname "$0")" && pwd)/scripts/setup/setup-oidc.sh"

  if [[ ! -f "$oidc_script" ]]; then
    echo "⚠️ scripts/setup/setup-oidc.sh not found. Skipping OIDC client registration."
    return 0
  fi

  if [[ -z "${KANIDM_ADMIN_PASSWORD:-}" ]]; then
    echo "⚠️ KANIDM_ADMIN_PASSWORD not set — run setup_identity first."
    return 0
  fi

  echo "Registering/syncing Kanidm OAuth2 clients..."
  local oidc_output
  oidc_output=$(bash "$oidc_script" 2>&1) || true

  local secrets_changed=false
  if echo "$oidc_output" | grep -q "^UPDATED_ENV"; then
    secrets_changed=true
    echo "🔄 OIDC secrets changed — re-sourcing .env..."
    set -a; source .env; set +a
  else
    echo "🔹 OIDC secrets already in sync with Kanidm."
  fi

  if [[ "$secrets_changed" == "true" || "$force_redeploy" == "force" ]]; then
    [[ "$force_redeploy" == "force" ]] && echo "Force-redeploying OIDC stacks to pick up current .env values..."
    [[ "$secrets_changed" == "true" ]] && echo "Redeploying stacks with updated OIDC secrets..."
    # Dynamically discover all stacks (including user stacks) that have a Kanidm OIDC
    # client label, so newly-added stacks are redeployed without editing this list.
    local repo_root
    repo_root="$(cd "$(dirname "$0")" && pwd)"
    local -A seen_stacks=()
    while IFS= read -r compose_file; do
      if grep -q 'kanidm\.oidc\.client_id=' "$compose_file" 2>/dev/null; then
        # Stack path relative to repo root (e.g. "stacks/quay" → "quay", "stacks/user/moodle" → "user/moodle")
        local stack_dir
        stack_dir=$(dirname "$compose_file")
        local stack_rel
        stack_rel="${stack_dir#"${repo_root}/stacks/"}"
        [[ -n "$stack_rel" && -z "${seen_stacks[$stack_rel]+_}" ]] && seen_stacks["$stack_rel"]=1
      fi
    done < <(find "${repo_root}/stacks" -not -path '*/_template/*' -name "docker-compose.yml" 2>/dev/null)
    for stack_rel in "${!seen_stacks[@]}"; do
      echo "  Redeploying ${stack_rel}..."
      ./deploy.sh "${stack_rel}" redeploy 2>/dev/null || echo "  ⚠️ ${stack_rel} redeploy failed (non-fatal)"
    done
    echo "✅ Affected stacks redeployed."
  else
    echo "🔹 Running containers already have current OIDC secrets — no redeployment needed."
  fi
}

# --- 4) Storage & SOC Secrets ---
setup_storage() {
  echo "--- 4) Secret Provisioning ---"
  
  # Hardcoded required secrets (non-OIDC)
  ensure_secret_and_env "DOJO_SECRET_KEY" "dojo_secret_key"

  # OAuth2 Proxy cookie secret (must be base64 that decodes to exactly 16, 24, or 32 raw bytes)
  if [ -z "${OAUTH2_PROXY_COOKIE_SECRET:-}" ]; then
    local cookie_secret
    cookie_secret="$(openssl rand -base64 32 | tr -d '\n')"
    create_secret "oauth2_proxy_cookie_secret" "$cookie_secret"
    write_env_secret "OAUTH2_PROXY_COOKIE_SECRET" "$cookie_secret"
  fi
}

# --- 4b) Storage Bucket Provisioning (SeaweedFS S3) ---
setup_storage_buckets() {
  echo "--- 4b) Storage Bucket Provisioning ---"
  # SeaweedFS S3 gateway is on port 8333 (internal) or s3.DOMAIN (external)
  wait_for_service "SeaweedFS S3" "run_on_node 'curl -m 5 -sf http://localhost:8333/'" || { echo "⚠️ SeaweedFS S3 not reachable, skipping bucket setup."; return 0; }

  local S3_GATEWAY="http://localhost:8333"
  local REQUIRED_BUCKETS=("loki-data")

  for bucket in "${REQUIRED_BUCKETS[@]}"; do
    # Check if bucket exists (GET /bucketname returns 200/404)
    local check_code
    check_code=$(run_on_node "curl -s -m 10 -o /dev/null -w '%{http_code}' '${S3_GATEWAY}/${bucket}/'")
    if [[ "$check_code" == "200" || "$check_code" == "403" ]]; then
      echo "🔹 Storage bucket '${bucket}' already exists."
    else
      local create_code
      create_code=$(run_on_node "curl -s -m 10 -o /dev/null -w '%{http_code}' -X PUT '${S3_GATEWAY}/${bucket}/'")
      if [[ "$create_code" == "200" || "$create_code" == "201" ]]; then
        echo "✅ Created storage bucket: ${bucket}"
      else
        echo "⚠️ Failed to create storage bucket '${bucket}' (HTTP ${create_code})."
      fi
    fi
  done
}

# --- 5) SOC (Wazuh & DefectDojo) ---
setup_soc() {
  echo "--- 5) SOC (Wazuh & DefectDojo) ---"
  wait_for_service "DefectDojo UI" "curl -m 5 -s -k -o /dev/null -w '%{http_code}' https://defectdojo.${DOMAIN}/ | grep -qE '^[1234]'" || echo "⚠️ Failed to wait for service, continuing anyway..."

  echo "Checking DefectDojo Admin Credentials..."
  if run_on_node "podman container exists defectdojo-django" 2>/dev/null; then
    DD_ADMIN_PASSWORD=$(run_on_node "podman logs defectdojo-django 2>&1" | grep "Admin password:" | awk -F': ' '{print $2}' | tr -d '\r' || echo "Already initialized")
    echo "✅ DefectDojo admin credentials captured (see .env for DEFECTDOJO_ADMIN_PASSWORD)."
    if [[ -n "$DD_ADMIN_PASSWORD" && "$DD_ADMIN_PASSWORD" != "Already initialized" ]]; then
      write_env_secret "DEFECTDOJO_ADMIN_PASSWORD" "$DD_ADMIN_PASSWORD"
    fi

    # Enable OAuth/SSO login button in DefectDojo.
    # DD_SOCIAL_AUTH_OIDC_ENABLED configures the Django backend but the login page button
    # is only shown when SystemSettings.enable_oauth is True in the database. These are
    # independent settings — the DB flag must be set post-init.
    echo "Enabling OAuth SSO button in DefectDojo SystemSettings..."
    run_on_node "podman exec defectdojo-django python manage.py shell -c \
      'from dojo.models import System_Settings; s=System_Settings.objects.first(); s.enable_oauth=True; s.save(); print(\"enable_oauth:\", s.enable_oauth)'" \
      2>/dev/null && echo "✅ DefectDojo SystemSettings.enable_oauth enabled." || \
      echo "⚠️ Could not set enable_oauth (container may still be initializing — re-run: ./setup-brain.sh soc)."
  else
    echo "⚠️ DefectDojo container not found."
  fi
}

# --- 5b) Gitea OIDC Auth Source ---
setup_gitea() {
  echo "--- 5b) Gitea OIDC Auth Source ---"
  if ! run_on_node "podman container exists gitea" 2>/dev/null; then
    echo "⚠️ Gitea container not found. Skipping."
    return 0
  fi

  wait_for_service "Gitea API" "curl -m 5 -s -k -f https://gitea.${DOMAIN}/api/healthz" || { echo "⚠️ Gitea not reachable, skipping."; return 0; }

  # Create local admin user (idempotent — fails silently if exists)
  # NOTE: Must exec as 'git' user — Gitea refuses to run as root.
  echo "Ensuring Gitea admin account exists..."
  run_on_node "podman exec --user git gitea gitea admin user create \
    --admin --username gitadmin \
    --password '${ADMIN_PASSWORD}' \
    --email 'gitadmin@${DOMAIN}' \
    --must-change-password=false" 2>/dev/null || true

  # Add Kanidm OIDC auth source (idempotent — check if exists first)
  local GITEA_SECRET="${GITEA_OIDC_SECRET:-}"
  if [[ -z "$GITEA_SECRET" ]]; then
    echo "⚠️ GITEA_OIDC_SECRET not set. Run setup_identity first."
    return 0
  fi

  local existing_source
  existing_source=$(run_on_node "podman exec --user git gitea gitea admin auth list" 2>/dev/null | grep -i "kanidm" || true)
  if [[ -n "$existing_source" ]]; then
    # Delete+re-add is necessary because `update-oauth --secret` does not reliably
    # persist the client secret in Gitea 1.21.x's SQLite DB. A stale secret in the
    # DB causes 401 on every token exchange even when Kanidm secrets are in sync.
    local auth_id
    auth_id=$(echo "$existing_source" | awk '{print $1}')
    echo "🔹 Gitea OIDC auth source 'kanidm' (ID: ${auth_id}) exists — recreating to ensure fresh secret..."
    run_on_node "podman exec --user git gitea gitea admin auth delete --id '${auth_id}'" 2>/dev/null || true
  fi
  # Always add (fresh install or after delete above).
  # NOTE: Do NOT include 'openid' in --scopes. Gitea appends it automatically to
  # all OIDC requests. Passing it here causes duplicate scope → Kanidm rejects.
  echo "Adding Kanidm OIDC auth source to Gitea..."
  if run_on_node "podman exec --user git gitea gitea admin auth add-oauth \
    --name kanidm \
    --provider openidConnect \
    --key gitea \
    --secret '${GITEA_SECRET}' \
    --auto-discover-url 'https://kanidm.${DOMAIN}/oauth2/openid/gitea/.well-known/openid-configuration' \
    --scopes 'profile email groups'" 2>/dev/null; then
    echo "✅ Gitea OIDC auth source configured (name=kanidm, secret fresh, scopes set)."
  else
    echo "⚠️ Failed to add Gitea OIDC auth source. Configure manually at https://gitea.${DOMAIN}/-/admin/auths/new"
  fi

  # Fetch and persist the runner registration token (idempotent).
  # NOTE: Gitea 1.21.x does not expose /api/v1/admin/runners/registration-token.
  # Tokens are written directly to the SQLite DB via podman unshare.
  # In action_runner_token: is_active=1 = valid/usable; is_active=0 = invalidated.
  echo "Ensuring Gitea runner registration token exists..."
  local current_token
  current_token=$(run_on_node "XDG_RUNTIME_DIR=/run/user/\$(id -u) podman unshare python3 -c \"
import sqlite3
DB='${DATA_DIR}/gitea/data/gitea/gitea.db'
try:
    conn = sqlite3.connect(DB)
    row = conn.execute('SELECT token FROM action_runner_token WHERE is_active=1 AND (deleted IS NULL OR deleted=0) AND owner_id=0 AND repo_id=0 ORDER BY id DESC LIMIT 1').fetchone()
    print(row[0] if row else '')
    conn.close()
except Exception as e:
    print('')
\" 2>/dev/null" 2>/dev/null || true)

  local env_token="${GITEA_RUNNER_TOKEN:-}"
  if [[ -z "$current_token" ]]; then
    # No valid token exists — generate and insert one
    local new_token
    new_token=$(python3 -c "import secrets; print(secrets.token_hex(20))" 2>/dev/null)
    run_on_node "XDG_RUNTIME_DIR=/run/user/\$(id -u) podman unshare python3 -c \"
import sqlite3, time
DB='${DATA_DIR}/gitea/data/gitea/gitea.db'
conn = sqlite3.connect(DB)
# Deactivate old tokens first
conn.execute(\\\"UPDATE action_runner_token SET is_active=0 WHERE owner_id=0 AND repo_id=0\\\")
now = int(time.time())
conn.execute(\\\"INSERT OR REPLACE INTO action_runner_token (token, owner_id, repo_id, is_active, created, updated) VALUES (?, 0, 0, 1, ?, ?)\\\", ('${new_token}', now, now))
conn.commit()
conn.close()
print('Token inserted')
\" 2>&1" 2>/dev/null || true
    write_env_secret "GITEA_RUNNER_TOKEN" "$new_token"
    echo "✅ Gitea runner registration token created and saved to .env."
    echo ">>> Redeploying Gitea runners to pick up new token..."
    ./deploy.sh gitea redeploy 2>/dev/null || true
  elif [[ "$current_token" != "$env_token" ]]; then
    # Token in DB differs from .env — sync .env
    write_env_secret "GITEA_RUNNER_TOKEN" "$current_token"
    echo "✅ Gitea runner token synced to .env."
    echo ">>> Redeploying Gitea runners to pick up token..."
    ./deploy.sh gitea redeploy 2>/dev/null || true
  else
    echo "🔹 Gitea runner token already valid and in sync."
  fi
}
# --- 5c) Moodle OIDC SSO ---
setup_moodle() {
  echo "--- 5c) Moodle OIDC SSO ---"
  if ! run_on_node "podman container exists moodle" 2>/dev/null; then
    echo "⚠️ Moodle container not found. Skipping."
    return 0
  fi

  local MOODLE_SECRET="${MOODLE_OIDC_SECRET:-}"
  if [[ -z "$MOODLE_SECRET" ]]; then
    echo "⚠️ MOODLE_OIDC_SECRET not set. Run setup_oidc first."
    return 0
  fi

  wait_for_service "Moodle" "run_on_node 'curl -m 10 -s -k -o /dev/null -w \"%{http_code}\" https://moodle.${DOMAIN}/login/index.php | grep -qE \"^[23]\"'" || { echo "⚠️ Moodle not reachable, skipping SSO setup."; return 0; }

  echo "Configuring Moodle OIDC SSO via exec..."
  run_on_node "podman exec \
    -e MOODLE_OIDC_SECRET='${MOODLE_SECRET}' \
    -e DOMAIN='${DOMAIN}' \
    -e MOODLE_WWWROOT='https://moodle.${DOMAIN}' \
    moodle bash /docker-entrypoint.d/30-setup-sso.sh" && \
    echo "✅ Moodle OIDC SSO configured." || \
    echo "⚠️ Moodle SSO setup returned non-zero (check: podman logs moodle)."
}

# --- 6) CrowdSec integration ---
setup_crowdsec() {
  echo "--- 6) CrowdSec integration ---"
  if run_on_node "podman container exists crowdsec" 2>/dev/null; then
    # The bouncer name "traefik" matches the BOUNCER_KEY_traefik env var in docker-compose.
    # The compose env var handles fresh installs; this function handles cases where the
    # bouncer was dropped from the CrowdSec DB (e.g. data volume wiped).
    local cs_key="${CROWDSEC_BOUNCER_API_KEY:-}"
    if [[ -z "$cs_key" ]]; then
      echo "⚠️ CROWDSEC_BOUNCER_API_KEY not set — skipping bouncer setup."
      return 0
    fi
    if ! run_on_node "podman exec crowdsec cscli bouncers list -o json" 2>/dev/null | grep -q '"traefik"'; then
      run_on_node "podman exec crowdsec cscli bouncers add traefik -k '${cs_key}'" 2>/dev/null && \
        echo "✅ CrowdSec 'traefik' bouncer registered using existing CROWDSEC_BOUNCER_API_KEY." || \
        echo "⚠️ CrowdSec bouncer registration failed (may already exist with this key)."
    else
      echo "🔹 CrowdSec 'traefik' bouncer already registered."
    fi
  else
    echo "⚠️ CrowdSec container not found. Skipping bouncer setup."
  fi
}

wait_proxies() {
  echo "Waiting for Proxies..."
  wait_for_service "Traefik" "run_on_node 'curl -m 5 -s -o /dev/null -w \"%{http_code}\" http://localhost/ping | grep -q 200'" || echo "⚠️ Traefik not reachable"
}

# --- Main execution ---
main() {
  local section="${1:-all}"

  echo "--- 0) Self-Healing & Pre-flight ---"
  if [[ "$PODMAN" == "podman" ]]; then
    for f in ${DATA_DIR}/kanidm/chain.pem ${DATA_DIR}/kanidm/key.pem; do
      if [ -d "$f" ]; then rm -rf "$f"; fi
    done
  fi

  if [[ "$section" == "all" || "$section" == "quay" ]]; then
    init_quay
  fi
  if [[ "$section" == "all" || "$section" == "pki" ]]; then
    echo ">>> [main] calling setup_pki"
    setup_pki
  fi
  if [[ "$section" == "all" || "$section" == "storage" || "$section" == "identity" ]]; then
    echo ">>> [main] calling setup_storage"
    setup_storage
  fi
  if [[ "$section" == "all" || "$section" == "storage" ]]; then
    echo ">>> [main] calling setup_storage_buckets"
    setup_storage_buckets
  fi
  if [[ "$section" == "all" || "$section" == "identity" ]]; then
    echo ">>> [main] calling setup_identity"
    setup_identity
  fi
  if [[ "$section" == "all" || "$section" == "oidc" ]]; then
    echo ">>> [main] calling setup_oidc"
    # When explicitly requested via 'oidc' section, force-redeploy so containers
    # that were started before secrets were written to .env pick up the correct values.
    if [[ "$section" == "oidc" ]]; then
      setup_oidc force
    else
      setup_oidc
    fi
  fi
  if [[ "$section" == "all" ]]; then
    echo ">>> [main] calling wait_proxies"
    wait_proxies
    echo ">>> [main] calling setup_soc"
    setup_soc
    echo ">>> [main] calling setup_gitea"
    setup_gitea
    echo ">>> [main] calling setup_moodle"
    setup_moodle
    echo ">>> [main] calling setup_crowdsec"
    setup_crowdsec
  fi
  if [[ "$section" == "gitea" ]]; then
    echo ">>> [main] calling setup_gitea"
    setup_gitea
  fi
  if [[ "$section" == "oidc" ]]; then
    # OIDC section also syncs the Gitea auth source (secret lives in Gitea DB, not env var)
    echo ">>> [main] calling setup_gitea (recreating Gitea auth source with fresh secret)"
    setup_gitea
    echo ">>> [main] calling setup_moodle (configuring Moodle OIDC SSO)"
    setup_moodle
  fi
  if [[ "$section" == "soc" ]]; then
    echo ">>> [main] calling setup_soc"
    setup_soc
  fi
  if [[ "$section" == "crowdsec" ]]; then
    echo ">>> [main] calling setup_crowdsec"
    setup_crowdsec
  fi
  
  echo "================================================="
  echo "🔐 BREAKGLASS & SSO SUMMARY"
  echo "================================================="
  echo "1. Kanidm: https://kanidm.${DOMAIN} | idm_admin recovery password captured (use ./scripts/create-kanidm-user.sh to create users)"
  echo "   ➡️  Create a UI login: ./scripts/create-kanidm-user.sh --role admin myadmin \"Global Admin\""
  echo "2. Storage: https://storage.${DOMAIN} | S3 API: https://s3.${DOMAIN}"
  echo "3. Quay: https://quay.${DOMAIN} | OIDC SSO Ready"
  echo "4. Wazuh: https://wazuh.${DOMAIN} | SSO via OAuth2 Proxy"
  echo "================================================="
}

main "$@"
