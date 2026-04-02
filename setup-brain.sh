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

# Persist a secret value into .env without overwriting existing entries.
write_env_secret() {
  local var_name="$1"
  local secret_value="$2"

  if [ ! -f .env ]; then
    touch .env
    chmod 600 .env
  fi

  if ! grep -q "^${var_name}=" .env 2>/dev/null; then
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
  wait_for_service "Quay API" "curl -s -k -f https://quay.${DOMAIN}/health/instance" || exit 1
  
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
}

# --- 2) PKI (Step-CA & Traefik ACME) ---
setup_pki() {
  echo "--- 2) PKI (Step-CA & Traefik ACME) ---"
  wait_for_service "Step-CA" "curl -s -k -f https://ca.${DOMAIN}/health" || exit 1

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
  wait_for_service "Kanidm" "curl -s -k -f https://kanidm.${DOMAIN}/" || exit 1

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
}

# --- 4) Storage & SOC Secrets ---
setup_storage() {
  echo "--- 4) Secret Provisioning ---"
  ensure_secret_and_env "MINIO_OIDC_SECRET" "minio_oidc_secret"
  ensure_secret_and_env "VAULTWARDEN_OIDC_SECRET" "vaultwarden_oidc_secret"
  ensure_secret_and_env "QUAY_OIDC_SECRET" "quay_oidc_secret"
  ensure_secret_and_env "WAZUH_OIDC_SECRET" "wazuh_oidc_secret"
  ensure_secret_and_env "DOJO_OIDC_SECRET" "dojo_oidc_secret"
  ensure_secret_and_env "DOJO_SECRET_KEY" "dojo_secret_key"
  ensure_secret_and_env "N8N_OIDC_SECRET" "n8n_oidc_secret"
}

# --- 5) SOC (Wazuh & DefectDojo) ---
setup_soc() {
  echo "--- 5) SOC (Wazuh & DefectDojo) ---"
  wait_for_service "DefectDojo UI" "curl -s -k -f https://defectdojo.${DOMAIN}/" || exit 1

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
  wait_for_service "Traefik" "curl -s -k -f https://traefik.${DOMAIN}/dashboard/" || echo "⚠️ Traefik dashboard not reachable"
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
  setup_pki
  setup_storage
  setup_identity
  wait_proxies
  setup_soc
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
