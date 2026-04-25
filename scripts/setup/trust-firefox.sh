#!/usr/bin/env bash
# =============================================================================
# trust-firefox.sh
# Imports the Step-CA root certificate into all local Firefox profiles
# so that the browser trusts the homelab's mTLS and HTTPS certificates.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CERT_FILE="$REPO_ROOT/stacks/traefik/config/certs/root_ca.crt"
CERT_NAME="Geo-Brain Homelab CA"

if [[ ! -f "$CERT_FILE" ]]; then
    echo "❌ Error: Root CA certificate not found at $CERT_FILE"
    exit 1
fi

if ! command -v certutil &> /dev/null; then
    echo "❌ Error: 'certutil' is not installed. Please install 'libnss3-tools' (or 'nss-tools' depending on your distro)."
    exit 1
fi

MOZILLA_DIR="$HOME/.mozilla/firefox"
if [[ ! -d "$MOZILLA_DIR" ]]; then
    echo "⚠️ No Firefox profiles found in $MOZILLA_DIR. If you use Flatpak/Snap, the path may differ."
    exit 0
fi

echo ">>> Importing '$CERT_NAME' into local Firefox profiles..."

# Find all cert9.db files in the Firefox directory
find "$MOZILLA_DIR" -name "cert9.db" -type f | while read -r certdb; do
    profile_dir=$(dirname "$certdb")
    echo "  -> Found profile: $profile_dir"
    
    # Check if already installed
    if certutil -L -d "sql:$profile_dir" -n "$CERT_NAME" &>/dev/null; then
        echo "     [SKIP] Certificate already installed."
    else
        # Add the certificate with trust flags for server authentication (C,C,C)
        certutil -A -n "$CERT_NAME" -t "C,," -i "$CERT_FILE" -d "sql:$profile_dir"
        echo "     [DONE] Certificate successfully imported!"
    fi
done

echo "================================================="
echo "✅ Complete! Restart Firefox for the changes to take effect."
echo "   Alternatively, you can go to about:config and set:"
echo "   security.enterprise_roots.enabled = true"
echo "   to force Firefox to use the system-wide certificate store."
echo "================================================="
