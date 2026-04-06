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
  init_resp=$(curl -s -k -X POST "${QUAY_API}/user/initialize" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"quayadmin\", \"password\": \"${ADMIN_PASSWORD}\", \"email\": \"admin@${DOMAIN}\"}" 2>/dev/null) || true
  QUAY_TOKEN=$(echo "$init_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true

  if [[ -z "$QUAY_TOKEN" ]]; then
    # Already initialized — login to get token
    QUAY_TOKEN=$(curl -s -k -X POST "${QUAY_API}/user/login" \
      -H "Content-Type: application/json" \
      -d "{\"user\": \"quayadmin\", \"password\": \"${ADMIN_PASSWORD}\"}" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true
  fi

  if [[ -n "$QUAY_TOKEN" ]]; then
    for upstream in "docker.io" "ghcr.io" "quay.io"; do
      local org_name="${upstream//./-}-cache"
      # Create organization
      curl -s -k -X POST "${QUAY_API}/organization/" \
        -H "Authorization: Bearer ${QUAY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${org_name}\", \"email\": \"${org_name}@${DOMAIN}\"}" 2>/dev/null || true
      # Enable proxy cache for the org
      curl -s -k -X POST "${QUAY_API}/organization/${org_name}/proxycache" \
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

  local step_ca_container
  step_ca_container=$($PODMAN ps -a --format "{{.Names}}" | grep step-ca | head -n 1 || echo "step-ca")

  echo "Adding ACME provisioner to Step-CA..."
  if $PODMAN exec "$step_ca_container" step ca provisioner list --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt | grep -q '"name": "acme"'; then
     echo "🔹 ACME provisioner already exists."
  else
     $PODMAN exec "$step_ca_container" step ca provisioner add acme --type ACME --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt
     $PODMAN kill -s SIGHUP "$step_ca_container"
     echo "✅ Added ACME provisioner to Step-CA."
  fi

  local traefik_container
  traefik_container=$($PODMAN ps -a --format "{{.Names}}" | grep traefik | head -n 1 || echo "traefik")
  
  echo "Injecting Step-CA Root into Traefik..."
  mkdir -p ./stacks/traefik/config/certs
  if $PODMAN exec "$step_ca_container" cat /home/step/certs/root_ca.crt > ./stacks/traefik/config/certs/root_ca.crt; then
    echo "✅ Traefik now trusts Step-CA."
  else
    echo "⚠️ Failed to inject Step-CA Root into Traefik. Traefik may not trust Step-CA."
  fi
}

# --- 3) Identity (Kanidm) ---
setup_identity() {
  echo "--- 3) Identity (Kanidm) ---"
  wait_for_service "Kanidm" "curl -m 5 -s -k -f https://kanidm.${DOMAIN}/" || echo "⚠️ Failed to wait for service, continuing anyway..."

  local kanidm_container
  kanidm_container=$($PODMAN ps -a --format "{{.Names}}" | grep kanidm | head -n 1 || echo "kanidm")

  echo "Initializing Kanidm Admin Account..."
  KANIDM_RECOVERY=$($PODMAN exec "$kanidm_container" /sbin/kanidmd recover-account -c /data/server.toml idm_admin 2>&1 | grep new_password | grep -o '"[^"]*"' | tr -d '"' || echo "")
  if [[ -n "$KANIDM_RECOVERY" ]]; then
    echo "✅ Kanidm idm_admin recovery password captured."
  else
    KANIDM_RECOVERY="Check container logs"
    echo "⚠️ Admin account recovery skipped or password not captured."
  fi

  echo "Automating Kanidm Service Accounts and OIDC Clients..."
  if [[ -n "$KANIDM_RECOVERY" ]] && [[ "$KANIDM_RECOVERY" != "Check container logs" ]]; then
    local CA_CERT_CONTENT
    CA_CERT_CONTENT=$(cat ./certs/ca.crt)
    
    local EXPECTED_APPS
    EXPECTED_APPS=$(find ./stacks -type f -name "docker-compose.yml" -exec grep -oP 'kanidm\.oidc\.client_id=\K[^"]+' {} \; 2>/dev/null | sort -u | tr '\n' ' ')

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

kanidm service-account create auth_svc 'Authelia Service Account' idm_admin -C /tmp/ca.crt >/dev/null 2>&1 || true
kanidm group add-members idm_unix_authentication_read auth_svc -C /tmp/ca.crt >/dev/null 2>&1 || true
kanidm group add-members idm_people_pii_read auth_svc -C /tmp/ca.crt >/dev/null 2>&1 || true
kanidm group add-members idm_account_mail_read auth_svc -C /tmp/ca.crt >/dev/null 2>&1 || true

if ! kanidm service-account api-token status auth_svc -C /tmp/ca.crt 2>/dev/null | grep -q "default"; then
   TOKEN=\$(kanidm service-account api-token generate auth_svc default -w -C /tmp/ca.crt 2>/dev/null | tail -n 1)
   echo "AUTHELIA_LDAP_PASSWORD_VALUE=\${TOKEN}"
fi

EXPECTED_APPS="${EXPECTED_APPS}"
for APP in \$EXPECTED_APPS; do
    kanidm system oauth2 create "\$APP" "\$APP OIDC" "https://\$APP.${DOMAIN}/" -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 warning-insecure-client-disable-pkce "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    # Map idm_all_persons to the standard scopes so all users can access the app
    kanidm system oauth2 update-scope-map "\$APP" idm_all_persons openid profile email -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    # Set the landing URL so the app appears on the Kanidm portal dashboard
    kanidm system oauth2 set-landing-url "\$APP" "https://\$APP.${DOMAIN}/" -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    SECRET=\$(kanidm system oauth2 show-basic-secret "\$APP" -C /tmp/ca.crt 2>/dev/null | tail -n 1)
    if [ "\$SECRET" = "No secret configured" ] || [ -z "\$SECRET" ]; then
        kanidm system oauth2 reset-basic-secret "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
        SECRET=\$(kanidm system oauth2 show-basic-secret "\$APP" -C /tmp/ca.crt 2>/dev/null | tail -n 1)
    fi
    echo "\${APP}_OIDC_SECRET_VALUE=\${SECRET}"
done

# Cleanup orphaned clients (Idempotency)
EXISTING_APPS=\$(kanidm system oauth2 list -C /tmp/ca.crt 2>/dev/null | grep "^name:" | awk '{print \$2}')
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
    setup_output=$(echo "$payload" | $PODMAN run -i --rm --network host --env KANIDM_PASSWORD="${KANIDM_RECOVERY}" docker.io/kanidm/tools:1.9.2 sh 2>/dev/null)
    
    # Process Authelia Password
    local authelia_pw
    authelia_pw=$(echo "$setup_output" | grep "^AUTHELIA_LDAP_PASSWORD_VALUE=" | cut -d'=' -f2-)
    if [[ -n "$authelia_pw" ]]; then
       # Force-update: the real Kanidm token must overwrite any placeholder
       sed -i "s|^AUTHELIA_LDAP_PASSWORD=.*|AUTHELIA_LDAP_PASSWORD=${authelia_pw}|" .env 2>/dev/null || true
       export AUTHELIA_LDAP_PASSWORD="$authelia_pw"
       echo "✅ Generated Kanidm API Token for Authelia."
       echo "⚠️ Note: You must restart Authelia to pick up the new AUTHELIA_LDAP_PASSWORD: ./deploy.sh authelia restart"
    fi

    # Process OIDC Secrets dynamically
    for APP in $EXPECTED_APPS; do
       local secret_val
       secret_val=$(echo "$setup_output" | grep -i "^${APP}_OIDC_SECRET_VALUE=" | cut -d'=' -f2-)
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
  EXPECTED_APPS=$(find ./stacks -type f -name "docker-compose.yml" -exec grep -oP 'kanidm\.oidc\.client_id=\K[^"]+' {} \; 2>/dev/null | sort -u)
  
  for APP in $EXPECTED_APPS; do
     local VAR_NAME="$(echo "${APP}_OIDC_SECRET" | tr '[:lower:]-' '[:upper:]_')"
     local SEC_NAME="${APP}_oidc_secret"
     ensure_secret_and_env "$VAR_NAME" "$SEC_NAME"
  done
  
  # Hardcoded required secrets (non-OIDC)
  ensure_secret_and_env "DOJO_SECRET_KEY" "dojo_secret_key"

  # Authelia secrets — placeholders so Authelia can start before setup_identity() runs
  ensure_secret_and_env "AUTHELIA_JWT_SECRET" "authelia_jwt_secret"
  ensure_secret_and_env "AUTHELIA_ENCRYPTION_KEY" "authelia_encryption_key"
  ensure_secret_and_env "AUTHELIA_LDAP_PASSWORD" "authelia_ldap_password"
}

# --- 5) SOC (Wazuh & DefectDojo) ---
setup_soc() {
  echo "--- 5) SOC (Wazuh & DefectDojo) ---"
  wait_for_service "DefectDojo UI" "curl -m 5 -s -k -f https://defectdojo.${DOMAIN}/" || echo "⚠️ Failed to wait for service, continuing anyway..."

  echo "Checking DefectDojo Admin Credentials..."
  local dd_init_container
  dd_init_container=$($PODMAN ps -a --format "{{.Names}}" | grep defectdojo-initializer | head -n 1 || true)
  if [[ -n "$dd_init_container" ]]; then
    DD_ADMIN_PASSWORD=$($PODMAN logs "$dd_init_container" 2>&1 | grep "Admin password:" | awk -F': ' '{print $2}' | tr -d '\r' || echo "Already initialized")
    echo "✅ DefectDojo Local Admin Password: $DD_ADMIN_PASSWORD"
  else
    echo "⚠️ DefectDojo initializer container not found."
  fi
}

# --- 6) CrowdSec integration ---
setup_crowdsec() {
  echo "--- 6) CrowdSec integration ---"
  if [[ "${ENABLE_CROWDSEC:-false}" == "true" ]]; then
    local crowdsec_container
    crowdsec_container=$($PODMAN ps --format "{{.Names}}" | grep crowdsec | head -n 1 || true)
    if [[ -n "$crowdsec_container" ]]; then
      if ! $PODMAN exec "$crowdsec_container" cscli bouncers list -o json | grep -q "bunkerweb-bouncer"; then
        CROWDSEC_BOUNCER_KEY=$($PODMAN exec "$crowdsec_container" cscli bouncers add bunkerweb-bouncer -o raw)
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
  echo "--- 0) Self-Healing & Pre-flight ---"
  if [[ "$PODMAN" == "podman" ]]; then
    for f in ${DATA_DIR}/kanidm/chain.pem ${DATA_DIR}/kanidm/key.pem; do
      if [ -d "$f" ]; then rm -rf "$f"; fi
    done
  fi

  init_quay
  echo ">>> [main] calling setup_pki"
  setup_pki
  echo ">>> [main] calling setup_storage"
  setup_storage
  echo ">>> [main] calling setup_identity"
  setup_identity
  echo ">>> [main] calling wait_proxies"
  wait_proxies
  echo ">>> [main] calling setup_soc"
  setup_soc
  echo ">>> [main] calling setup_crowdsec"
  setup_crowdsec
  
  echo "================================================="
  echo "🔐 BREAKGLASS & SSO SUMMARY"
  echo "================================================="
  echo "1. Kanidm: https://kanidm.${DOMAIN} | Admin: idm_admin | Recovery: ${KANIDM_RECOVERY:-Check container logs}"
  echo "2. MinIO: https://minio.${DOMAIN} | Admin: ${MINIO_ROOT_USER:-minioadmin} / ${MINIO_ROOT_PASSWORD:-[REDACTED]}"
  echo "3. Quay: https://quay.${DOMAIN} | OIDC SSO Ready"
  echo "4. Wazuh: https://wazuh.${DOMAIN} | SSO via Authelia"
  echo "5. n8n: https://n8n.${DOMAIN} | OIDC SSO Ready"
  echo "================================================="
}

main "$@"
