#!/bin/bash
# @GEMINI.md: Single Source of Truth for this script's mandates.
# setup-brain.sh
# Idempotent rootless Podman setup script for the STIG-Homelab environment
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
DATA_DIR=${DATA_DIR:-/var/STIG-Homelab}
DATA_DIR="${DATA_DIR/#\~/$HOME}"

echo "Starting STIG-Homelab post-deployment rootless bootstrapper..."

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

# --- 4b) MinIO Bucket Provisioning ---
setup_minio() {
  echo "--- 4b) MinIO Bucket Provisioning ---"
  wait_for_service "MinIO" "run_on_node 'curl -m 5 -sf http://localhost:9000/minio/health/live'" || { echo "⚠️ MinIO not reachable, skipping bucket setup."; return 0; }

  local MINIO_CONSOLE="http://localhost:9001"
  local MINIO_USER="${MINIO_ROOT_USER:-minioadmin}"
  local MINIO_PASS="${MINIO_ROOT_PASSWORD}"
  local COOKIE_JAR="/tmp/.minio-cookies-$$"
  local REQUIRED_BUCKETS=("loki-data")

  # Login to MinIO Console API
  local login_code
  login_code=$(run_on_node "curl -s -m 10 -o /dev/null -w '%{http_code}' -c '${COOKIE_JAR}' -X POST '${MINIO_CONSOLE}/api/v1/login' -H 'Content-Type: application/json' -d '{\"accessKey\":\"${MINIO_USER}\",\"secretKey\":\"${MINIO_PASS}\"}'")
  if [[ "$login_code" != "204" ]]; then
    echo "⚠️ MinIO Console login failed (HTTP ${login_code}). Skipping bucket setup."
    run_on_node "rm -f '${COOKIE_JAR}'" 2>/dev/null
    return 0
  fi

  for bucket in "${REQUIRED_BUCKETS[@]}"; do
    # Check if bucket exists
    local exists
    exists=$(run_on_node "curl -s -m 10 -b '${COOKIE_JAR}' '${MINIO_CONSOLE}/api/v1/buckets' 2>/dev/null" | grep -c "\"name\":\"${bucket}\"" || true)
    if [[ "$exists" -gt 0 ]]; then
      echo "🔹 MinIO bucket '${bucket}' already exists."
    else
      local create_code
      create_code=$(run_on_node "curl -s -m 10 -o /dev/null -w '%{http_code}' -b '${COOKIE_JAR}' -X POST '${MINIO_CONSOLE}/api/v1/buckets' -H 'Content-Type: application/json' -d '{\"name\":\"${bucket}\"}'")
      if [[ "$create_code" == "200" || "$create_code" == "201" ]]; then
        echo "✅ Created MinIO bucket: ${bucket}"
      else
        echo "⚠️ Failed to create MinIO bucket '${bucket}' (HTTP ${create_code})."
      fi
    fi
  done

  run_on_node "rm -f '${COOKIE_JAR}'" 2>/dev/null
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
    --admin --username admin \
    --password '${ADMIN_PASSWORD}' \
    --email 'admin@${DOMAIN}' \
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
    echo "🔹 Gitea OIDC auth source 'kanidm' already exists."
  else
    echo "Adding Kanidm OIDC auth source to Gitea..."
    if run_on_node "podman exec --user git gitea gitea admin auth add-oauth \
      --name Kanidm \
      --provider openidConnect \
      --key gitea \
      --secret '${GITEA_SECRET}' \
      --auto-discover-url 'https://kanidm.${DOMAIN}/oauth2/openid/gitea/.well-known/openid-configuration' \
      --scopes 'openid profile email groups'" 2>/dev/null; then
      echo "✅ Gitea OIDC auth source configured for Kanidm."
    else
      echo "⚠️ Failed to add Gitea OIDC auth source. Configure manually at https://gitea.${DOMAIN}/-/admin/auths/new"
    fi
  fi
}

# --- 6) CrowdSec integration ---
setup_crowdsec() {
  echo "--- 6) CrowdSec integration ---"
  if run_on_node "podman container exists crowdsec" 2>/dev/null; then
    # Register a bouncer for the Traefik plugin if not already present
    if ! run_on_node "podman exec crowdsec cscli bouncers list -o json" 2>/dev/null | grep -q "traefik-bouncer"; then
      CROWDSEC_KEY=$(run_on_node "podman exec crowdsec cscli bouncers add traefik-bouncer -o raw" 2>/dev/null)
      if [[ -n "$CROWDSEC_KEY" ]]; then
        write_env_secret "CROWDSEC_BOUNCER_API_KEY" "$CROWDSEC_KEY"
        echo "✅ Created CrowdSec Bouncer API Key for Traefik."
        echo ">>> Redeploying Traefik to pick up bouncer key..."
        ./deploy.sh traefik up
      fi
    else
      echo "🔹 CrowdSec traefik-bouncer already registered."
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
    echo ">>> [main] calling setup_minio"
    setup_minio
  fi
  if [[ "$section" == "all" || "$section" == "identity" ]]; then
    echo ">>> [main] calling setup_identity"
    setup_identity
  fi
  if [[ "$section" == "all" ]]; then
    echo ">>> [main] calling wait_proxies"
    wait_proxies
    echo ">>> [main] calling setup_soc"
    setup_soc
    echo ">>> [main] calling setup_gitea"
    setup_gitea
    echo ">>> [main] calling setup_crowdsec"
    setup_crowdsec
  fi
  
  echo "================================================="
  echo "🔐 BREAKGLASS & SSO SUMMARY"
  echo "================================================="
  echo "1. Kanidm: https://kanidm.${DOMAIN} | idm_admin recovery password captured (use ./scripts/create-kanidm-user.sh to create users)"
  echo "   ➡️  Create a UI login: ./scripts/create-kanidm-user.sh --role admin myadmin \"Global Admin\""
  echo "2. MinIO: https://minio.${DOMAIN} | Credentials in .env (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD)"
  echo "3. Quay: https://quay.${DOMAIN} | OIDC SSO Ready"
  echo "4. Wazuh: https://wazuh.${DOMAIN} | SSO via OAuth2 Proxy"
  echo "================================================="
}

main "$@"
