#!/usr/bin/env bash
# setup-geo-brain.sh
# Idempotent rootless Podman setup script for the Geo Brain environment
# This script configures Harbor, Identity (Kanidm), PKI (Step-CA), SOC (DefectDojo/Wazuh), and Proxy.

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
DATA_DIR=${DATA_DIR:-/var/brain-ssof}

echo "Starting Geo Brain post-deployment rootless bootstrapper..."

# --- Helper Functions ---

# Function for exponential backoff health checks
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
    # Cap backoff at 30 seconds
    if [ $backoff -lt 30 ]; then
      backoff=$((backoff * 2))
    fi
  done

  echo "❌ Error: ${service_name} failed to become ready after ${MAX_RETRIES} retries."
  return 1
}

# Function to create podman secret idempotently
create_secret() {
  local secret_name=$1
  local secret_value=$2

  if podman secret ls --format "{{.Name}}" | grep -q "^${secret_name}$"; then
    echo "🔹 Secret ${secret_name} already exists. Skipping."
  else
    echo -n "$secret_value" | podman secret create "$secret_name" -
    echo "✅ Created podman secret: ${secret_name}"
  fi
}

# --- 1) Harbor First Initialization ---
init_harbor() {
  echo "--- 1) Harbor Initialization ---"
  
  # Wait for Harbor Core API
  wait_for_service "Harbor API" "curl -s -k -f https://harbor.${DOMAIN}/api/v2.0/health" || exit 1
  
  echo "Changing Harbor admin password..."
  # Harbor default admin is 'admin' / 'Harbor12345'
  # We attempt to change it to ADMIN_PASSWORD. If it fails, we assume it's already changed.
  curl -s -k -u "admin:Harbor12345" -X PUT -H "Content-Type: application/json" \
    -d "{\"old_password\": \"Harbor12345\", \"new_password\": \"${ADMIN_PASSWORD}\"}" \
    "https://harbor.${DOMAIN}/api/v2.0/users/1/password" || echo "🔹 Harbor password may already be changed."
  
  create_secret "harbor_admin_password" "$ADMIN_PASSWORD"

  # Enforce Harbor as primary registry in Podman (Rootless context requires user config)
  mkdir -p ~/.config/containers
  cat <<EOF > ~/.config/containers/registries.conf
[[registry]]
location = "harbor.${DOMAIN}"
insecure = false
EOF
  echo "✅ Configured Podman to use Harbor as a registry."
}

# --- 2) PKI (Step-CA & Traefik ACME) ---
setup_pki() {
  echo "--- 2) PKI (Step-CA & Traefik ACME) ---"
  
  # Wait for Step-CA
  wait_for_service "Step-CA" "curl -s -k -f https://ca.${DOMAIN}/health" || exit 1

  echo "Adding ACME provisioner to Step-CA..."
  # Check if ACME provisioner exists
  if podman exec step-ca step ca provisioner list | grep -q '"name": "acme"'; then
     echo "🔹 ACME provisioner already exists."
  else
     # The step-ca container might run as a specific user, ensure we have rights.
     podman exec step-ca step ca provisioner add acme --type ACME
     echo "Reloading Step-CA..."
     podman kill -s SIGHUP step-ca
     echo "✅ ACME provisioner added to Step-CA."
  fi

  echo "Injecting Step-CA Root Certificate into Traefik..."
  # Extract the root CA. We assume Step-CA volume is mounted at ${DATA_DIR}/step-ca/step
  # OR we can pull it via step cli inside the container
  mkdir -p ./stacks/traefik/config/certs
  if [ ! -f ./stacks/traefik/config/certs/root_ca.crt ]; then
      podman exec step-ca cat /home/step/certs/root_ca.crt > ./stacks/traefik/config/certs/root_ca.crt
      echo "✅ Copied root_ca.crt to Traefik certs directory."
  else
      echo "🔹 Traefik already has root_ca.crt."
  fi
}

# --- 3) Identity (Kanidm & Vaultwarden OIDC) ---
setup_identity() {
  echo "--- 3) Identity (Kanidm & Vaultwarden OIDC) ---"
  
  # Wait for Kanidm
  wait_for_service "Kanidm" "curl -s -k -f https://idm.${DOMAIN}/status" || exit 1
  
  # Recover token (if it doesn't exist, we can't easily auto-gen here unless we know it's a fresh install, 
  # but let's assume kanidm is fresh and we can recover admin or we use a pre-set admin password).
  # Assuming kanidm was initialized and we have a way to authenticate.
  # For Kanidm, we usually need the recovery password. 
  echo "🔹 Note: Kanidm automated OIDC client creation requires an active session or recovery token."
  
  # Vaultwarden OIDC client secret
  VAULTWARDEN_OIDC_SECRET=$(openssl rand -base64 32)
  create_secret "vaultwarden_oidc_secret" "$VAULTWARDEN_OIDC_SECRET"

  # Harbor OIDC client secret
  HARBOR_OIDC_SECRET=$(openssl rand -base64 32)
  create_secret "harbor_oidc_secret" "$HARBOR_OIDC_SECRET"

  # DefectDojo OIDC client secret
  DOJO_OIDC_SECRET=$(openssl rand -base64 32)
  create_secret "dojo_oidc_secret" "$DOJO_OIDC_SECRET"

  echo "✅ Identity secrets generated. (Manual Kanidm CLI commands or a Kanidm init script may be needed to register the clients)."
}

# --- 4) Management/Proxy Wait ---
wait_proxies() {
  echo "--- 4) Waiting for Proxies & Management ---"
  wait_for_service "Traefik" "curl -s -k https://traefik.${DOMAIN}/ping" || echo "⚠️ Traefik ping failed, continuing..."
}

# --- 5) SOC (Wazuh & DefectDojo) ---
setup_soc() {
  echo "--- 5) SOC (Wazuh & DefectDojo) ---"
  
  # DefectDojo
  # Wait for DefectDojo Login page
  wait_for_service "DefectDojo UI" "curl -s -k https://defectdojo.${DOMAIN}/login" || echo "⚠️ DefectDojo UI check failed."

  echo "Checking DefectDojo Admin Credentials..."
  # If we have initializer logs, extract the password.
  # This requires knowing the exact container name. Let's assume 'defectdojo-initializer' or similar.
  DD_INIT_CONTAINER=$(podman ps -a --format "{{.Names}}" | grep defectdojo-initializer || true)
  if [ -n "$DD_INIT_CONTAINER" ]; then
    DD_ADMIN_PASSWORD=$(podman logs "$DD_INIT_CONTAINER" 2>&1 | grep "Admin password:" | awk -F': ' '{print $2}' | tr -d '\r')
    if [ -n "$DD_ADMIN_PASSWORD" ]; then
      echo "✅ Extracted DefectDojo Admin Password from logs."
      # Authenticate to get API key
      DD_TOKEN_RESPONSE=$(curl -s -k -X POST -H "Content-Type: application/json" \
        -d "{\"username\": \"admin\", \"password\": \"${DD_ADMIN_PASSWORD}\"}" \
        "https://defectdojo.${DOMAIN}/api/v2/api-token-auth/")
      
      DD_API_KEY=$(echo "$DD_TOKEN_RESPONSE" | grep -o '"token":"[^"]*' | grep -o '[^"]*$')
      
      if [ -n "$DD_API_KEY" ]; then
        create_secret "DOJO_API_KEY" "$DD_API_KEY"
      else
        echo "⚠️ Failed to extract DOJO_API_KEY from API response."
      fi
    else
      echo "⚠️ Could not find 'Admin password:' in $DD_INIT_CONTAINER logs."
    fi
  else
    echo "⚠️ DefectDojo initializer container not found. Cannot extract initial password automatically."
  fi
}

# --- 6) CrowdSec placeholder ---
setup_crowdsec() {
  echo "--- 6) CrowdSec integration ---"
  
  if [ "${ENABLE_CROWDSEC:-false}" = "true" ]; then
    echo "Setting up CrowdSec Bouncer for BunkerWeb..."
    # Ensure crowdsec is running
    if podman ps --format "{{.Names}}" | grep -q "crowdsec"; then
      if podman exec crowdsec cscli bouncers list -o json | grep -q "bunkerweb-bouncer"; then
        echo "🔹 bunkerweb-bouncer already exists."
      else
        CROWDSEC_BOUNCER_KEY=$(podman exec crowdsec cscli bouncers add bunkerweb-bouncer -o raw)
        create_secret "crowdsec_bouncer_key" "$CROWDSEC_BOUNCER_KEY"
      fi
    else
      echo "⚠️ CrowdSec container not running."
    fi
  else
    echo "🔹 CrowdSec integration disabled (set ENABLE_CROWDSEC=true to enable)."
  fi
}

# --- Main Execution ---
main() {
  echo "================================================="
  echo "Geo Brain - Rootless DevSecOps Bootstrapper"
  echo "================================================="
  
  init_harbor
  setup_pki
  setup_identity
  wait_proxies
  setup_soc
  setup_crowdsec
  
  echo "================================================="
  echo "🎉 Geo Brain setup script completed successfully."
  echo "================================================="
}

main "$@"
