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
CERT_NAME="STIG-Homelab Homelab CA"

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
echo ">>> Attempting to install CA into the system trust store..."
echo "    (This enables Firefox's 'security.enterprise_roots.enabled' feature)"
echo "    You may be prompted for your sudo password."

if [ -d "/etc/pki/ca-trust/source/anchors/" ]; then
    # Fedora / CentOS / RHEL
    if sudo cp "$CERT_FILE" /etc/pki/ca-trust/source/anchors/stig-homelab-ca.crt; then
        sudo update-ca-trust
        echo "    [DONE] System trust store updated (Fedora/RHEL)."
    else
        echo "    [WARN] Failed to copy to /etc/pki/ca-trust/source/anchors/. Skipping system-wide trust."
    fi
elif [ -d "/usr/local/share/ca-certificates/" ]; then
    # Ubuntu / Debian
    if sudo cp "$CERT_FILE" /usr/local/share/ca-certificates/stig-homelab-ca.crt; then
        sudo update-ca-certificates
        echo "    [DONE] System trust store updated (Debian/Ubuntu)."
    else
        echo "    [WARN] Failed to copy to /usr/local/share/ca-certificates/. Skipping system-wide trust."
    fi
else
    echo "    [WARN] OS trust store directory not recognized. Skipping system-wide trust."
fi

echo "================================================="
echo "✅ Complete! Restart Firefox for the changes to take effect."
echo "   Since 'security.enterprise_roots.enabled' is true, Firefox"
echo "   will now natively trust the STIG-Homelab CA from the OS store."
echo "================================================="
