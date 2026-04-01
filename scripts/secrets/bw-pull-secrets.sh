#!/usr/bin/env bash
# bw-pull-secrets.sh
# Pulls secrets from Vaultwarden using Bitwarden CLI (bw) and provisions them as Podman secrets.
# Requires BW_CLIENTID and BW_CLIENTSECRET to be set in environment for machine-to-machine auth.

set -euo pipefail

# Ensure session is cleaned up on exit
cleanup() {
    if [ -n "${BW_SESSION:-}" ]; then
        bw logout 2>/dev/null || true
        unset BW_SESSION
    fi
}
trap cleanup EXIT

# Check for Bitwarden CLI
if ! command -v bw >/dev/null 2>&1; then
    echo "❌ Error: Bitwarden CLI (bw) is not installed."
    exit 1
fi

DOMAIN=${DOMAIN:-geo-brain.local}
BW_URL=${BW_URL:-"https://vaultwarden.${DOMAIN}"}

if [ -z "${BW_CLIENTID:-}" ] || [ -z "${BW_CLIENTSECRET:-}" ]; then
    echo "❌ Error: BW_CLIENTID and BW_CLIENTSECRET must be set for authentication."
    exit 1
fi

echo "Authenticating with Vaultwarden at ${BW_URL}..."
bw config server "${BW_URL}"

# Login using API key
BW_SESSION=$(bw login --apikey --raw)
export BW_SESSION

if [ -z "${BW_SESSION}" ]; then
    echo "❌ Error: Authentication failed. Check BW_CLIENTID and BW_CLIENTSECRET."
    exit 1
fi

# Function to fetch and provision a secret
provision_secret() {
    local secret_name=$1
    local item_id=$2
    
    echo "Fetching secret ${secret_name}..."
    local secret_value
    secret_value=$(bw get password "$item_id")
    
    if podman secret ls --format "{{.Name}}" | grep -q "^${secret_name}$"; then
        echo "🔹 Secret ${secret_name} already exists. Skipping."
    else
        echo -n "$secret_value" | podman secret create "$secret_name" -
        echo "✅ Created podman secret: ${secret_name}"
    fi
}

echo "Provisioning secrets from Vaultwarden to Podman..."

# Example: Provisioning a database password
# provision_secret "quay_db_password" "<bitwarden-item-uuid>"

# Sync vault
bw sync

echo "✅ Secret provisioning complete."
