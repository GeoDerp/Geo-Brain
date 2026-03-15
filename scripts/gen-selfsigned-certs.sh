#!/usr/bin/env bash
# =============================================================================
# gen-selfsigned-certs.sh — Self-Signed CA + Wildcard Certs (generate or import)
# =============================================================================
# Generates a local CA and wildcard certificate for ${DOMAIN}, or imports an
# existing certificate/key pair and normalises it to the expected filenames.
# Deploys certs to required stacks:
#   - Traefik (TLS termination for *.${DOMAIN})
#   - Kanidm  (native HTTPS on port 8443)
# Also installs the CA into the local and remote host trust stores.
#
# Usage:
#   ./scripts/gen-selfsigned-certs.sh [OPTIONS]
#
# Options:
#   --deploy        Deploy certs to remote host and restart affected containers
#   --trust-local   Install CA into local system trust store
#   --trust-remote  Install CA into remote host system trust store
#   --all           All of the above (deploy + trust-local + trust-remote)
#   --import <cert.crt> <cert.key>
#                   Import an existing cert/key pair as the wildcard cert.
#                   DER-encoded inputs are automatically converted to PEM.
#                   Skips CA and wildcard generation steps.
#   --ca <ca.crt>   CA cert to bundle in chain files (used with --import).
#                   If omitted, the existing certs/ca.crt is used if present.
# =============================================================================
set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_DIR="$REPO_ROOT/certs"
DOMAIN="${DOMAIN:-example.local}"
CA_DAYS=3650    # CA valid 10 years
CERT_DAYS=825   # Leaf cert valid ~2.25 years (Apple max)
KEY_SIZE=4096
CA_SUBJECT="/C=US/ST=Local/L=Homelab/O=GEO-Brain/OU=SSOF/CN=${DOMAIN} Temporary CA"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
REMOTE_HOST="${REMOTE_HOST:-homelab.local}"
REMOTE_USER="${REMOTE_USER:-$USER}"
DATA_DIR="${DATA_DIR:-/var/brain-ssof}"

# --- Parse args ---
DO_DEPLOY=false
DO_TRUST_LOCAL=false
DO_TRUST_REMOTE=false
IMPORT_CERT=""
IMPORT_KEY=""
IMPORT_CA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy)       DO_DEPLOY=true; shift ;;
    --trust-local)  DO_TRUST_LOCAL=true; shift ;;
    --trust-remote) DO_TRUST_REMOTE=true; shift ;;
    --all)          DO_DEPLOY=true; DO_TRUST_LOCAL=true; DO_TRUST_REMOTE=true; shift ;;
    --import)
      shift
      IMPORT_CERT="${1:?--import requires <cert.crt> <cert.key>}"
      shift
      IMPORT_KEY="${1:?--import requires <cert.crt> <cert.key>}"
      shift
      ;;
    --ca)
      shift
      IMPORT_CA="${1:?--ca requires <ca.crt>}"
      shift
      ;;
    -h|--help)
      sed -n '2,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

ssh_cmd() {
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

# Convert a certificate file to PEM if it is DER-encoded.
pem_convert_cert() {
  local src="$1" dst="$2"
  if openssl x509 -inform PEM -in "$src" -noout 2>/dev/null; then
    cp "$src" "$dst"
  elif openssl x509 -inform DER -in "$src" -noout 2>/dev/null; then
    echo "    Converting DER → PEM: $(basename "$src")"
    openssl x509 -inform DER -in "$src" -out "$dst"
  else
    echo "[ERROR] Cannot parse certificate: $src" >&2
    exit 1
  fi
}

# Convert a private key file to PEM if it is DER-encoded.
pem_convert_key() {
  local src="$1" dst="$2"
  if openssl pkey -in "$src" -noout 2>/dev/null; then
    cp "$src" "$dst"
  elif openssl pkey -inform DER -in "$src" -noout 2>/dev/null; then
    echo "    Converting DER key → PEM: $(basename "$src")"
    openssl pkey -inform DER -in "$src" -out "$dst"
  else
    echo "[ERROR] Cannot parse private key: $src" >&2
    exit 1
  fi
}

# --- Step 1: Create output directory ---
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

echo ">>> Certificate output directory: $CERT_DIR"
echo ">>> Domain: $DOMAIN"

# --- Steps 2–4: Import existing cert/key OR generate new CA + certs ---
if [[ -n "$IMPORT_CERT" ]]; then
  echo ">>> Import mode: using provided certificate..."

  [[ -f "$IMPORT_CERT" ]] || { echo "[ERROR] Cert not found: $IMPORT_CERT" >&2; exit 1; }
  [[ -f "$IMPORT_KEY" ]]  || { echo "[ERROR] Key not found: $IMPORT_KEY" >&2; exit 1; }

  pem_convert_cert "$IMPORT_CERT" "$CERT_DIR/wildcard.crt"
  pem_convert_key  "$IMPORT_KEY"  "$CERT_DIR/wildcard.key"
  chmod 644 "$CERT_DIR/wildcard.crt"
  chmod 600 "$CERT_DIR/wildcard.key"
  echo "    Wildcard cert: $CERT_DIR/wildcard.crt"
  echo "    Wildcard key:  $CERT_DIR/wildcard.key"

  # Handle CA cert — prefer explicit --ca, fall back to existing certs/ca.crt
  if [[ -n "$IMPORT_CA" ]]; then
    [[ -f "$IMPORT_CA" ]] || { echo "[ERROR] CA cert not found: $IMPORT_CA" >&2; exit 1; }
    pem_convert_cert "$IMPORT_CA" "$CERT_DIR/ca.crt"
    chmod 644 "$CERT_DIR/ca.crt"
    echo "    CA cert (imported): $CERT_DIR/ca.crt"
  elif [[ -f "$CERT_DIR/ca.crt" ]]; then
    echo "    CA cert (existing): $CERT_DIR/ca.crt"
  else
    echo "    [INFO] No CA cert provided or found — chain bundles will be cert-only."
    echo "    Use --ca <ca.crt> to include a CA cert in chain files."
  fi

  # Use wildcard cert for Kanidm (no CA key available to sign a dedicated cert)
  cp "$CERT_DIR/wildcard.crt" "$CERT_DIR/kanidm.crt"
  cp "$CERT_DIR/wildcard.key" "$CERT_DIR/kanidm.key"
  if [[ -f "$CERT_DIR/ca.crt" ]]; then
    cat "$CERT_DIR/kanidm.crt" "$CERT_DIR/ca.crt" > "$CERT_DIR/kanidm-chain.crt"
  else
    cp "$CERT_DIR/kanidm.crt" "$CERT_DIR/kanidm-chain.crt"
  fi
  echo "    Kanidm cert:  $CERT_DIR/kanidm.crt  (wildcard cert re-used)"
  echo "    Kanidm chain: $CERT_DIR/kanidm-chain.crt"
  echo "    Kanidm key:   $CERT_DIR/kanidm.key"

else
  # --- Step 2: Generate CA key + cert ---
  if [[ -f "$CERT_DIR/ca.crt" && -f "$CERT_DIR/ca.key" ]]; then
    echo ">>> CA already exists, reusing ($CERT_DIR/ca.crt)"
  else
    echo ">>> Generating Certificate Authority..."
    openssl genrsa -out "$CERT_DIR/ca.key" "$KEY_SIZE" 2>/dev/null
    chmod 600 "$CERT_DIR/ca.key"

    openssl req -x509 -new -nodes \
      -key "$CERT_DIR/ca.key" \
      -sha256 \
      -days "$CA_DAYS" \
      -subj "$CA_SUBJECT" \
      -out "$CERT_DIR/ca.crt"

    echo "    CA cert: $CERT_DIR/ca.crt"
    echo "    CA key:  $CERT_DIR/ca.key"
  fi

  # --- Step 3: Generate wildcard cert for Traefik ---
  echo ">>> Generating wildcard certificate for *.$DOMAIN ..."

  # Create SAN config
  cat > "$CERT_DIR/san.cnf" <<SANEOF
[req]
default_bits       = $KEY_SIZE
distinguished_name = req_dn
req_extensions     = v3_req
prompt             = no

[req_dn]
C  = US
ST = Local
L  = Homelab
O  = GEO-Brain
OU = SSOF
CN = *.${DOMAIN}

[v3_req]
basicConstraints     = CA:FALSE
keyUsage             = digitalSignature, keyEncipherment
extendedKeyUsage     = serverAuth
subjectAltName       = @alt_names

[alt_names]
DNS.1 = *.${DOMAIN}
DNS.2 = ${DOMAIN}
DNS.3 = localhost
IP.1  = 127.0.0.1
SANEOF

  # Generate key + CSR
  openssl genrsa -out "$CERT_DIR/wildcard.key" "$KEY_SIZE" 2>/dev/null
  chmod 600 "$CERT_DIR/wildcard.key"

  openssl req -new \
    -key "$CERT_DIR/wildcard.key" \
    -config "$CERT_DIR/san.cnf" \
    -out "$CERT_DIR/wildcard.csr"

  # Sign with our CA
  openssl x509 -req \
    -in "$CERT_DIR/wildcard.csr" \
    -CA "$CERT_DIR/ca.crt" \
    -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERT_DIR/wildcard.crt" \
    -days "$CERT_DAYS" \
    -sha256 \
    -extfile "$CERT_DIR/san.cnf" \
    -extensions v3_req

  echo "    Wildcard cert: $CERT_DIR/wildcard.crt"
  echo "    Wildcard key:  $CERT_DIR/wildcard.key"

  # --- Step 4: Generate Kanidm cert (needs specific SANs) ---
  echo ">>> Generating Kanidm certificate..."

  cat > "$CERT_DIR/kanidm-san.cnf" <<KANEOF
[req]
default_bits       = $KEY_SIZE
distinguished_name = req_dn
req_extensions     = v3_req
prompt             = no

[req_dn]
C  = US
ST = Local
L  = Homelab
O  = GEO-Brain
OU = SSOF
CN = kanidm.${DOMAIN}

[v3_req]
basicConstraints     = CA:FALSE
keyUsage             = digitalSignature, keyEncipherment
extendedKeyUsage     = serverAuth
subjectAltName       = @alt_names

[alt_names]
DNS.1 = kanidm.${DOMAIN}
DNS.2 = kanidm
DNS.3 = localhost
IP.1  = 127.0.0.1
KANEOF

  openssl genrsa -out "$CERT_DIR/kanidm.key" "$KEY_SIZE" 2>/dev/null
  chmod 600 "$CERT_DIR/kanidm.key"

  openssl req -new \
    -key "$CERT_DIR/kanidm.key" \
    -config "$CERT_DIR/kanidm-san.cnf" \
    -out "$CERT_DIR/kanidm.csr"

  openssl x509 -req \
    -in "$CERT_DIR/kanidm.csr" \
    -CA "$CERT_DIR/ca.crt" \
    -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERT_DIR/kanidm.crt" \
    -days "$CERT_DAYS" \
    -sha256 \
    -extfile "$CERT_DIR/kanidm-san.cnf" \
    -extensions v3_req

  # Kanidm needs a chain file (cert + CA)
  cat "$CERT_DIR/kanidm.crt" "$CERT_DIR/ca.crt" > "$CERT_DIR/kanidm-chain.crt"

  echo "    Kanidm cert:  $CERT_DIR/kanidm.crt"
  echo "    Kanidm chain: $CERT_DIR/kanidm-chain.crt"
  echo "    Kanidm key:   $CERT_DIR/kanidm.key"

fi  # end import/generate

# --- Step 5: Write Traefik dynamic TLS config ---
echo ">>> Writing Traefik TLS dynamic configuration..."
cat > "$REPO_ROOT/stacks/traefik/config/dynamic/tls.yml" <<TLSEOF
# Auto-generated by gen-selfsigned-certs.sh — DO NOT EDIT
# Traefik default TLS certificate for *.$DOMAIN
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/wildcard.crt
        keyFile:  /etc/traefik/certs/wildcard.key

  certificates:
    - certFile: /etc/traefik/certs/wildcard.crt
      keyFile:  /etc/traefik/certs/wildcard.key
TLSEOF

echo "    Written: stacks/traefik/config/dynamic/tls.yml"

# --- Step 6: Create cert directories for volume mounts ---
echo ">>> Preparing cert directories for container mounts..."
TRAEFIK_CERTS="$REPO_ROOT/stacks/traefik/config/certs"
mkdir -p "$TRAEFIK_CERTS"
cp "$CERT_DIR/wildcard.crt" "$TRAEFIK_CERTS/wildcard.crt"
cp "$CERT_DIR/wildcard.key" "$TRAEFIK_CERTS/wildcard.key"
chmod 644 "$TRAEFIK_CERTS/wildcard.crt"
chmod 600 "$TRAEFIK_CERTS/wildcard.key"
if [[ -f "$CERT_DIR/ca.crt" ]]; then
  cp "$CERT_DIR/ca.crt" "$TRAEFIK_CERTS/ca.crt"
  chmod 644 "$TRAEFIK_CERTS/ca.crt"
fi
echo "    Copied to: stacks/traefik/config/certs/"

# --- Step 7: Verify the cert ---
echo ""
echo ">>> Certificate verification:"
openssl x509 -in "$CERT_DIR/wildcard.crt" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | head -10
echo ""

# --- Step 8: Deploy to remote ---
if $DO_DEPLOY; then
  echo ">>> Deploying certificates to remote host ($REMOTE_HOST)..."

  # Deploy Kanidm cert to remote data dir
  ssh_cmd "mkdir -p $DATA_DIR/kanidm/certs"
  scp -i "$SSH_KEY" -o BatchMode=yes \
    "$CERT_DIR/kanidm-chain.crt" \
    "$CERT_DIR/kanidm.key" \
    "${REMOTE_USER}@${REMOTE_HOST}:${DATA_DIR}/kanidm/certs/"

  # Fix Kanidm cert ownership (kanidm runs as PUID:PGID inside container)
  ssh_cmd "chmod 644 $DATA_DIR/kanidm/certs/kanidm-chain.crt && chmod 600 $DATA_DIR/kanidm/certs/kanidm.key"

  echo "    Kanidm certs deployed to $DATA_DIR/kanidm/certs/"

  # Deploy will sync traefik certs via normal deploy.sh rsync
  echo "    Traefik certs will be deployed via deploy.sh (in config/certs/)"
  echo ""
  echo ">>> Redeploying affected stacks..."
  cd "$REPO_ROOT"
  bash deploy.sh traefik up 2>&1 | tail -5
  echo ""
  bash deploy.sh kanidm up 2>&1 | tail -5
  echo ""
  echo ">>> Deploy complete."
fi

# --- Step 9: Trust CA on local machine ---
if $DO_TRUST_LOCAL; then
  echo ">>> Installing CA into local trust store..."

  # Detect OS and install accordingly
  if command -v update-ca-trust &>/dev/null; then
    # RHEL/Fedora/openSUSE
    sudo cp "$CERT_DIR/ca.crt" /etc/pki/ca-trust/source/anchors/brain-ssof-ca.crt
    sudo update-ca-trust
    echo "    Installed via update-ca-trust (RHEL/Fedora/SUSE)"
  elif command -v update-ca-certificates &>/dev/null; then
    # Debian/Ubuntu
    sudo cp "$CERT_DIR/ca.crt" /usr/local/share/ca-certificates/brain-ssof-ca.crt
    sudo update-ca-certificates
    echo "    Installed via update-ca-certificates (Debian/Ubuntu)"
  else
    echo "    [WARN] Could not detect trust store mechanism."
    echo "    Manually install: $CERT_DIR/ca.crt"
  fi

  # Firefox/Chrome use NSS — try to add there too
  if command -v certutil &>/dev/null; then
    for certdb in $(find "$HOME" -name "cert9.db" -path "*/mozilla/*" 2>/dev/null); do
      dbdir="$(dirname "$certdb")"
      certutil -A -n "brain-ssof-ca" -t "CT,C,C" -i "$CERT_DIR/ca.crt" -d "sql:$dbdir" 2>/dev/null && \
        echo "    Added to NSS DB: $dbdir" || true
    done
  fi
fi

# --- Step 10: Trust CA on remote host ---
if $DO_TRUST_REMOTE; then
  echo ">>> Installing CA into remote host trust store ($REMOTE_HOST)..."
  scp -i "$SSH_KEY" -o BatchMode=yes \
    "$CERT_DIR/ca.crt" \
    "${REMOTE_USER}@${REMOTE_HOST}:/tmp/brain-ssof-ca.crt"

  ssh_cmd "sudo cp /tmp/brain-ssof-ca.crt /etc/pki/ca-trust/source/anchors/brain-ssof-ca.crt 2>/dev/null || \
           sudo cp /tmp/brain-ssof-ca.crt /usr/local/share/ca-certificates/brain-ssof-ca.crt 2>/dev/null; \
           sudo update-ca-trust 2>/dev/null || sudo update-ca-certificates 2>/dev/null; \
           rm -f /tmp/brain-ssof-ca.crt; \
           echo 'CA installed on remote'"
fi

echo ""
echo "=== Summary ==="
echo "  CA cert:       $CERT_DIR/ca.crt"
echo "  Wildcard cert: $CERT_DIR/wildcard.crt  (for Traefik)"
echo "  Kanidm cert:   $CERT_DIR/kanidm-chain.crt"
echo "  Traefik TLS:   stacks/traefik/config/dynamic/tls.yml"
echo "  Traefik certs: stacks/traefik/config/certs/"
echo ""
echo "Next steps:"
echo "  1. Run: ./scripts/gen-selfsigned-certs.sh --all"
echo "     (to deploy + trust on both hosts)"
echo "  2. Or manually: bash deploy.sh traefik up && bash deploy.sh kanidm up"
echo "  3. Verify: curl -v https://home.$DOMAIN (should show valid cert)"
echo ""
echo ">>> Done."
