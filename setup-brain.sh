#!/bin/bash
# setup-brain.sh
# Idempotent rootless Podman setup script for the Geo Brain environment
# This script configures Quay, Identity (Kanidm), PKI (Step-CA), SOC (DefectDojo/Wazuh), and Proxy.

set -euo pipefail

# --- Configuration & Seed Variables ---
if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

# Fallback/Default variables if not in .env
DOMAIN=${DOMAIN:-geo-brain.local}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-"ChangeMe123!"}
MAX_RETRIES=15
INITIAL_BACKOFF=2
DATA_DIR=${DATA_DIR:-/var/Geo-Brain}
DATA_DIR="${DATA_DIR/#\~/$HOME}"

echo "Starting Geo Brain post-deployment rootless bootstrapper..."

# --- Podman Connection Wrapper ---
# This allows the script to be run from the host OR directly on the target node.
PODMAN="podman"
if [[ -n "${REMOTE_HOST:-}" ]]; then
  # If we are on the host, REMOTE_HOST is defined. Check for a connection.
  if podman system connection ls --format '{{.Name}} {{.URI}}' | grep -q "${REMOTE_HOST}"; then
    CONN_NAME=$(podman system connection ls --format '{{.Name}} {{.URI}}' | grep "${REMOTE_HOST}" | awk '{print $1}' | head -n 1)
    PODMAN="podman --connection ${CONN_NAME}"
    echo "🔹 Using remote podman connection: ${CONN_NAME}"
  else
    # If we are ALREADY on the remote host, REMOTE_HOST might still be in .env.
    # Check if we are running on the host that matches REMOTE_HOST.
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

  if $PODMAN secret ls --format "{{.Name}}" | grep -q "^${secret_name}$"; then
    echo "🔹 Secret ${secret_name} already exists. Skipping."
  else
    echo -n "$secret_value" | $PODMAN secret create "$secret_name" -
    echo "✅ Created podman secret: ${secret_name}"
  fi
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
  $PODMAN exec "$step_ca_container" cat /home/step/certs/root_ca.crt > ./stacks/traefik/config/certs/root_ca.crt || true
  echo "✅ Traefik now trusts Step-CA."
}

# --- 3) Identity (Kanidm) ---
setup_identity() {
  echo "--- 3) Identity (Kanidm) ---"
  wait_for_service "Kanidm" "curl -s -k -f https://kanidm.${DOMAIN}/healthz" || exit 1

  local kanidm_container
  kanidm_container=$($PODMAN ps -a --format "{{.Names}}" | grep kanidm | head -n 1 || echo "kanidm")

  echo "Initializing Kanidm Admin Account..."
  $PODMAN exec "$kanidm_container" /sbin/kanidmd recover-account -c /data/server.toml idm_admin || echo "⚠️ Admin account recovery skipped."
}

# --- 4) Storage (MinIO) ---
setup_storage() {
  echo "--- 4) Storage (MinIO) ---"
  create_secret "minio_oidc_secret" "$(openssl rand -base64 32)"
  create_secret "vaultwarden_oidc_secret" "$(openssl rand -base64 32)"
  create_secret "quay_oidc_secret" "$(openssl rand -base64 32)"
  create_secret "wazuh_oidc_secret" "$(openssl rand -base64 32)"
  create_secret "dojo_oidc_secret" "$(openssl rand -base64 32)"
  create_secret "n8n_oidc_secret" "$(openssl rand -base64 32)"
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
  # Self-healing for erroneous directories
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
  local kanidm_container
  kanidm_container=$($PODMAN ps -a --format "{{.Names}}" | grep kanidm | head -n 1 || echo "kanidm")
  
  KANIDM_RECOVERY=$($PODMAN exec "$kanidm_container" /sbin/kanidmd recover-account -c /data/server.toml idm_admin 2>&1 | grep new_password | grep -o '"[^"]*"' | tr -d '"' || echo "Check container logs")
  echo "1. Kanidm: https://kanidm.${DOMAIN} | Admin: idm_admin | Recovery: $KANIDM_RECOVERY"
  echo "2. MinIO: https://minio.${DOMAIN} | Admin: ${MINIO_ROOT_USER:-minioadmin} / ${MINIO_ROOT_PASSWORD:-[REDACTED]}"
  echo "3. Quay: https://quay.${DOMAIN} | OIDC SSO Ready"
  echo "4. Wazuh: https://wazuh.${DOMAIN} | OIDC SSO Ready"
  echo "5. n8n: https://n8n.${DOMAIN} | Local Auth (Configure OIDC in UI)"
  echo "================================================="
}

main "$@"
