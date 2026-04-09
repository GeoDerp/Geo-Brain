#!/bin/bash
# setup-brain.sh
# Idempotent rootless Podman setup script for the Geo Brain environment
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
DOMAIN=${DOMAIN:-geo-brain.local}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-"ChangeMe123!"}
MAX_RETRIES=15
INITIAL_BACKOFF=2
DATA_DIR=${DATA_DIR:-/var/Geo-Brain}
DATA_DIR="${DATA_DIR/#\~/$HOME}"

echo "Starting Geo Brain post-deployment rootless bootstrapper..."

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
SSH_CMD=""
if [[ -n "${REMOTE_HOST:-}" ]] && [[ -n "${SSH_KEY:-}" ]]; then
    _ssh_key="${SSH_KEY/#\~/$HOME}"
    SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=120 -o ServerAliveInterval=10 -o ServerAliveCountMax=30 -i ${_ssh_key} -p ${SSH_PORT:-22} ${REMOTE_USER}@${REMOTE_HOST}"
fi

run_on_node() {
    if [[ -n "$SSH_CMD" ]]; then
        $SSH_CMD "$@"
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

  if grep -q "^${var_name}=$" .env 2>/dev/null; then
    # Key exists but is empty (e.g., copied from .env-template) — update in place
    sed -i "s|^${var_name}=$|${var_name}=${secret_value}|" .env
  elif ! grep -q "^${var_name}=" .env 2>/dev/null; then
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
unqualified-search-registries = ["quay.${DOMAIN}", "docker.io"]

[[registry]]
prefix = "docker.io"
location = "quay.${DOMAIN}"
insecure = false
mirror-by-digest-only = false

[[registry]]
location = "quay.${DOMAIN}"
insecure = false
EOF
  echo "✅ Configured Podman registries.conf."

  # Create proxy cache organizations for upstream registries
  local QUAY_API="https://quay.${DOMAIN}/api/v1"
  local QUAY_TOKEN=""

  # Initialize admin user if first run (FEATURE_USER_INITIALIZE=true)
  local init_resp
  init_resp=$(curl -m 10 -s -k -X POST "${QUAY_API}/user/initialize" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"quayadmin\", \"password\": \"${ADMIN_PASSWORD}\", \"email\": \"admin@${DOMAIN}\"}" 2>/dev/null) || true
  QUAY_TOKEN=$(echo "$init_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true

  if [[ -z "$QUAY_TOKEN" ]]; then
    # Already initialized — login to get token
    QUAY_TOKEN=$(curl -m 10 -s -k -X POST "${QUAY_API}/user/login" \
      -H "Content-Type: application/json" \
      -d "{\"user\": \"quayadmin\", \"password\": \"${ADMIN_PASSWORD}\"}" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true
  fi

  if [[ -n "$QUAY_TOKEN" ]]; then
    for upstream in "docker.io" "ghcr.io" "quay.io"; do
      local org_name="${upstream//./-}-cache"
      # Create organization
      curl -m 10 -s -k -X POST "${QUAY_API}/organization/" \
        -H "Authorization: Bearer ${QUAY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${org_name}\", \"email\": \"${org_name}@${DOMAIN}\"}" 2>/dev/null || true
      # Enable proxy cache for the org
      curl -m 10 -s -k -X POST "${QUAY_API}/organization/${org_name}/proxycache" \
        -H "Authorization: Bearer ${QUAY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"upstream_registry\": \"${upstream}\"}" 2>/dev/null || true
    done
    echo "✅ Configured proxy cache organizations for docker.io, ghcr.io, quay.io."
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
  else
    KANIDM_RECOVERY="Check container logs"
    echo "⚠️ Admin account recovery skipped or password not captured."
  fi

  echo "Automating Kanidm OIDC Clients..."
  if [[ -n "$KANIDM_RECOVERY" ]] && [[ "$KANIDM_RECOVERY" != "Check container logs" ]]; then
    local CA_CERT_CONTENT
    CA_CERT_CONTENT=$(cat ./certs/ca.crt)
    
    local EXPECTED_APPS
    EXPECTED_APPS=$(find ./stacks -not -path './stacks/_template/*' -type f -name "docker-compose.yml" -exec grep -oP 'kanidm\.oidc\.client_id=\K[^"]+' {} \; 2>/dev/null | sort -u | tr '\n' ' ')

    local payload=$(cat <<EOF
#!/bin/sh
set -e
export KANIDM_URL="https://kanidm.${DOMAIN}"
export KANIDM_NAME="idm_admin"
export KANIDM_PASSWORD="${KANIDM_RECOVERY}"

cat << 'CAEOF' > /tmp/ca.crt
${CA_CERT_CONTENT}
CAEOF

kanidm login -C /tmp/ca.crt >/dev/null 2>&1 || exit 1

EXPECTED_APPS="${EXPECTED_APPS}"
for APP in \$EXPECTED_APPS; do
    # Set redirect URL based on app name
    if [ "\$APP" = "oauth2-proxy" ]; then
        REDIRECT_URL="https://auth.${DOMAIN}/oauth2/callback"
    else
        REDIRECT_URL="https://\$APP.${DOMAIN}/"
    fi

    kanidm system oauth2 create "\$APP" "\$APP OIDC" "\$REDIRECT_URL" -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 warning-insecure-client-disable-pkce "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    # Map idm_all_persons to the standard scopes so all users can access the app
    kanidm system oauth2 update-scope-map "\$APP" idm_all_persons openid profile email -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    # Set the landing URL so the app appears on the Kanidm portal dashboard
    kanidm system oauth2 set-landing-url "\$APP" "\$REDIRECT_URL" -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    SECRET=\$(kanidm system oauth2 show-basic-secret "\$APP" -C /tmp/ca.crt 2>/dev/null | tail -n 1)
    if [ "\$SECRET" = "No secret configured" ] || [ -z "\$SECRET" ]; then
        kanidm system oauth2 reset-basic-secret "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
        SECRET=\$(kanidm system oauth2 show-basic-secret "\$APP" -C /tmp/ca.crt 2>/dev/null | tail -n 1)
    fi
    echo "\${APP}_OIDC_SECRET_VALUE=\${SECRET}"
done

# Cleanup orphaned clients (Idempotency)
EXISTING_APPS=\$(kanidm system oauth2 list -C /tmp/ca.crt 2>/dev/null | grep "^name:" | cut -d' ' -f2)
for EXISTING in \$EXISTING_APPS; do
    if echo "\$EXPECTED_APPS" | grep -qw "\$EXISTING"; then
        continue
    fi
    echo "⚠️ Deleting orphaned Kanidm OIDC client: \$EXISTING"
    kanidm system oauth2 delete "\$EXISTING" -C /tmp/ca.crt >/dev/null 2>&1 || true
done
EOF
)

    local setup_output
    setup_output=$(echo "$payload" | $PODMAN run -i --rm --network host --env KANIDM_PASSWORD="${KANIDM_RECOVERY}" docker.io/kanidm/tools:1.9.2 sh 2>&1) || {
      echo "⚠️ Kanidm OIDC automation failed (exit $?). Output:"
      echo "$setup_output"
    }

    # Process OAuth2 Proxy OIDC secret and redeploy
    local oauth2_proxy_secret
    oauth2_proxy_secret=$(echo "$setup_output" | grep "^oauth2-proxy_OIDC_SECRET_VALUE=" | cut -d'=' -f2- || true)
    if [[ -n "$oauth2_proxy_secret" ]] && [[ "$oauth2_proxy_secret" != "No secret configured" ]]; then
       write_env_secret "OAUTH2_PROXY_CLIENT_SECRET" "$oauth2_proxy_secret"
       echo "✅ Generated Kanidm OIDC secret for OAuth2 Proxy."
       echo ">>> Redeploying OAuth2 Proxy to pick up fresh OIDC config..."
       ./deploy.sh oauth2-proxy up 2>&1 || echo "⚠️ OAuth2 Proxy redeploy failed — run manually: ./deploy.sh oauth2-proxy up"
    fi

    # Process OIDC Secrets dynamically for all other apps
    for APP in $EXPECTED_APPS; do
       [[ "$APP" == "oauth2-proxy" ]] && continue
       local secret_val
       secret_val=$(echo "$setup_output" | grep -i "^${APP}_OIDC_SECRET_VALUE=" | cut -d'=' -f2- || true)
       if [[ -n "$secret_val" ]] && [[ "$secret_val" != "No secret configured" ]]; then
          local var_name=$(echo "${APP}_OIDC_SECRET" | tr '[:lower:]-' '[:upper:]_')
          write_env_secret "$var_name" "$secret_val"
       fi
    done
    echo "✅ Kanidm programmatic setup complete."
  fi
}

# --- 4) Storage & SOC Secrets ---
setup_storage() {
  echo "--- 4) Secret Provisioning ---"
  
  local EXPECTED_APPS
  EXPECTED_APPS=$(find ./stacks -not -path './stacks/_template/*' -type f -name "docker-compose.yml" -exec grep -oP 'kanidm\.oidc\.client_id=\K[^"]+' {} \; 2>/dev/null | sort -u)
  
  for APP in $EXPECTED_APPS; do
     local VAR_NAME="$(echo "${APP}_OIDC_SECRET" | tr '[:lower:]-' '[:upper:]_')"
     local SEC_NAME="${APP}_oidc_secret"
     ensure_secret_and_env "$VAR_NAME" "$SEC_NAME"
  done
  
  # Hardcoded required secrets (non-OIDC)
  ensure_secret_and_env "DOJO_SECRET_KEY" "dojo_secret_key"

  # OAuth2 Proxy cookie secret (must be exactly 16, 24, or 32 raw bytes)
  if [ -z "${OAUTH2_PROXY_COOKIE_SECRET:-}" ]; then
    local cookie_secret
    cookie_secret="$(openssl rand -hex 16)"
    create_secret "oauth2_proxy_cookie_secret" "$cookie_secret"
    write_env_secret "OAUTH2_PROXY_COOKIE_SECRET" "$cookie_secret"
  fi
}

# --- 5) SOC (Wazuh & DefectDojo) ---
setup_soc() {
  echo "--- 5) SOC (Wazuh & DefectDojo) ---"
  wait_for_service "DefectDojo UI" "curl -m 5 -s -k -f https://defectdojo.${DOMAIN}/" || echo "⚠️ Failed to wait for service, continuing anyway..."

  echo "Checking DefectDojo Admin Credentials..."
  if run_on_node "podman container exists defectdojo-django" 2>/dev/null; then
    DD_ADMIN_PASSWORD=$(run_on_node "podman logs defectdojo-django 2>&1" | grep "Admin password:" | awk -F': ' '{print $2}' | tr -d '\r' || echo "Already initialized")
    echo "✅ DefectDojo Local Admin Password: $DD_ADMIN_PASSWORD"
  else
    echo "⚠️ DefectDojo container not found."
  fi
}

# --- 6) CrowdSec integration ---
setup_crowdsec() {
  echo "--- 6) CrowdSec integration ---"
  if [[ "${ENABLE_CROWDSEC:-false}" == "true" ]]; then
    if run_on_node "podman container exists crowdsec" 2>/dev/null; then
      if ! run_on_node "podman exec crowdsec cscli bouncers list -o json" | grep -q "bunkerweb-bouncer"; then
        CROWDSEC_BOUNCER_KEY=$(run_on_node "podman exec crowdsec cscli bouncers add bunkerweb-bouncer -o raw")
        echo "✅ Created CrowdSec Bouncer Key for BunkerWeb: $CROWDSEC_BOUNCER_KEY"
      fi
    fi
  else
    echo "🔹 CrowdSec integration disabled."
  fi
}

wait_proxies() {
  echo "Waiting for Proxies..."
  wait_for_service "Traefik" "curl -m 5 -s -k -f https://traefik.${DOMAIN}/dashboard/" || echo "⚠️ Traefik dashboard not reachable"
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
  if [[ "$section" == "all" || "$section" == "identity" ]]; then
    echo ">>> [main] calling setup_identity"
    setup_identity
  fi
  if [[ "$section" == "all" ]]; then
    echo ">>> [main] calling wait_proxies"
    wait_proxies
    echo ">>> [main] calling setup_soc"
    setup_soc
    echo ">>> [main] calling setup_crowdsec"
    setup_crowdsec
  fi
  
  echo "================================================="
  echo "🔐 BREAKGLASS & SSO SUMMARY"
  echo "================================================="
  echo "1. Kanidm: https://kanidm.${DOMAIN} | idm_admin Recovery: ${KANIDM_RECOVERY:-Check container logs}"
  echo "   ➡️  Create a UI login: ./scripts/create-kanidm-user.sh myadmin \"Global Admin\""
  echo "2. MinIO: https://minio.${DOMAIN} | Admin: ${MINIO_ROOT_USER:-minioadmin} / ${MINIO_ROOT_PASSWORD:-[REDACTED]}"
  echo "3. Quay: https://quay.${DOMAIN} | OIDC SSO Ready"
  echo "4. Wazuh: https://wazuh.${DOMAIN} | SSO via OAuth2 Proxy"
  echo "================================================="
}

main "$@"
