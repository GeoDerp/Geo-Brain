# Extract values from existing .env
BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENVFILE="$BASE_DIR/.env"
set -a; [ -f "$ENVFILE" ] && source "$ENVFILE"; set +a

if [[ -z "${KANIDM_ADMIN_PASSWORD:-}" ]]; then
  # Try to recover it
  KANIDM_ADMIN_PASSWORD=$(systemd-run --user --wait -p Type=oneshot -- sh -c "podman exec kanidm /sbin/kanidmd recover-account -c /data/server.toml idm_admin > /tmp/kanidm-recovery.tmp 2>&1" 2>/dev/null; grep new_password /tmp/kanidm-recovery.tmp 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || true)
fi

if [[ -z "$KANIDM_ADMIN_PASSWORD" ]]; then
  echo "No Kanidm admin password available."
  exit 0
fi

CA_CERT_CONTENT=$(cat "$BASE_DIR/stacks/traefik/config/certs/ca-bundle.crt" 2>/dev/null || cat "$BASE_DIR/stacks/traefik/config/certs/root_ca.crt" 2>/dev/null || cat "$BASE_DIR/certs/ca.crt" 2>/dev/null || true)
if [[ -z "$CA_CERT_CONTENT" ]]; then
  echo "No CA cert found."
  exit 0
fi

EXPECTED_APPS=""
RAW_APPS=$(find "$BASE_DIR/stacks" -not -path '*/_template/*' -type f -name "docker-compose.yml" 2>/dev/null)
for compose in $RAW_APPS; do
   # Find all unique client IDs in this file
   client_ids=$(grep -oP 'kanidm\.oidc\.client_id=\K[^"]+' "$compose" | sort -u || true)
   for app_id in $client_ids; do
       if [[ -n "$app_id" ]]; then
           # Try to find the specific subdomain for THIS client_id if possible
           # For oauth2-proxy-admin, we want to detect if it has a different Host rule
           # We use awk to find the labels block following the client_id
           subdomain=$(grep -oP "traefik\.http\.routers\.[^.]+\.rule=Host\(\`\K[^.\`]+" "$compose" | head -n 1 || echo "$app_id")
           
           # Read redirect_path from compose label (kanidm.oidc.redirect_path=<path>)
           # Special-case oauth2-proxy instances: their callbacks are on the root domain
           redirect_path=""
           case "$app_id" in
               oauth2-proxy)       redirect_path="/oauth2/callback" ;;
               oauth2-proxy-admin) redirect_path="/admin-oauth2/callback" ;;
               *)
                   redirect_path=$(grep -oP 'kanidm\.oidc\.redirect_path=\K[^"]+' "$compose" | head -n 1 || true)
                   redirect_path="${redirect_path:-/}"
                   ;;
           esac
           EXPECTED_APPS="$EXPECTED_APPS ${app_id}:${subdomain}:${redirect_path}"
       fi
   done
done
EXPECTED_APPS=$(echo "$EXPECTED_APPS" | xargs) # trim whitespace

payload=$(cat <<INNEREOF
#!/bin/sh
set -e
export KANIDM_URL="https://kanidm.${DOMAIN}"
export KANIDM_NAME="idm_admin"
export KANIDM_PASSWORD="${KANIDM_ADMIN_PASSWORD}"

cat << 'CAEOF' > /tmp/ca.crt
${CA_CERT_CONTENT}
CAEOF

kanidm login -C /tmp/ca.crt >/dev/null 2>&1 || exit 1

# --- Create RBAC groups (idempotent) ---
kanidm group create stig_admins -C /tmp/ca.crt >/dev/null 2>&1 || true
kanidm group create stig_users -C /tmp/ca.crt >/dev/null 2>&1 || true

EXPECTED_APPS="${EXPECTED_APPS}"
for APP_INFO in \$EXPECTED_APPS; do
    APP="\${APP_INFO%%:*}"
    REST="\${APP_INFO#*:}"
    SUBDOMAIN="\${REST%%:*}"
    REDIRECT_PATH="\${REST#*:}"
    
    ORIGIN_URL="https://\${SUBDOMAIN}.${DOMAIN}"
    REDIRECT_URL="\${ORIGIN_URL}\${REDIRECT_PATH}"

    kanidm system oauth2 create "\$APP" "\$APP OIDC" "\$ORIGIN_URL" -C /tmp/ca.crt >/dev/null 2>&1 || true
    # Ensure the primary redirect URL is added (in case it wasn't created initially with it)
    kanidm system oauth2 add-redirect-url "\$APP" "https://\${SUBDOMAIN}.${DOMAIN}\${REDIRECT_PATH}" -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 add-redirect-url "\$APP" "\${REDIRECT_URL}" -C /tmp/ca.crt >/dev/null 2>&1 || true
    # Register additional common variants
    if [ "\$APP" = "grafana" ]; then
         kanidm system oauth2 add-redirect-url "\$APP" "https://grafana.${DOMAIN}/login/generic_oauth" -C /tmp/ca.crt >/dev/null 2>&1 || true
    fi
    # Register oauth2-proxy clients
    if [ "\$APP" = "oauth2-proxy" ]; then
        kanidm system oauth2 add-redirect-url "\$APP" "https://${DOMAIN}/oauth2/callback" -C /tmp/ca.crt >/dev/null 2>&1 || true
    fi
    if [ "\$APP" = "oauth2-proxy-admin" ]; then
        kanidm system oauth2 add-redirect-url "\$APP" "https://${DOMAIN}/admin-oauth2/callback" -C /tmp/ca.crt >/dev/null 2>&1 || true
    fi

    # Enable RS256 (legacy crypto) for all clients for maximum JWT compatibility.
    # Kanidm defaults to ES256-only; RS256 is needed by Quay and improves compat
    # with Python/PHP OIDC libraries that may not support EC keys.
    kanidm system oauth2 warning-enable-legacy-crypto "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 warning-insecure-client-disable-pkce "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    kanidm system oauth2 delete-scope-map "\$APP" idm_all_persons -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 update-scope-map "\$APP" stig_admins openid profile email groups -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 update-scope-map "\$APP" stig_users openid profile email groups -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 set-landing-url "\$APP" "\$ORIGIN_URL" -C /tmp/ca.crt >/dev/null 2>&1 || true
    
    SECRET=\$(kanidm system oauth2 show-basic-secret "\$APP" -C /tmp/ca.crt 2>/dev/null | tail -n 1)
    if [ "\$SECRET" = "No secret configured" ] || [ -z "\$SECRET" ]; then
        kanidm system oauth2 reset-basic-secret "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
        SECRET=\$(kanidm system oauth2 show-basic-secret "\$APP" -C /tmp/ca.crt 2>/dev/null | tail -n 1)
    fi
    echo "\${APP}_OIDC_SECRET_VALUE=\${SECRET}"
done

EXISTING_APPS=\$(kanidm system oauth2 list -C /tmp/ca.crt 2>/dev/null | grep "^name:" | cut -d' ' -f2)
for EXISTING in \$EXISTING_APPS; do
    if echo "\$EXPECTED_APPS" | grep -qE "\b\${EXISTING}:"; then
        continue
    fi
    kanidm system oauth2 delete "\$EXISTING" -C /tmp/ca.crt >/dev/null 2>&1 || true
done
INNEREOF
)

setup_output=$(echo "$payload" | DBUS_SESSION_BUS_ADDRESS="" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" podman run -i --rm --network host --env KANIDM_PASSWORD="${KANIDM_ADMIN_PASSWORD}" docker.io/kanidm/tools:1.9.2 sh 2>&1) || true

UPDATED_ENV=false

# Process OAuth2 Proxy OIDC secret first
oauth2_proxy_secret=$(echo "$setup_output" | grep "^oauth2-proxy_OIDC_SECRET_VALUE=" | cut -d'=' -f2- || true)
if [[ -n "$oauth2_proxy_secret" ]] && [[ "$oauth2_proxy_secret" != "No secret configured" ]]; then
   current_val=$(grep "^OAUTH2_PROXY_CLIENT_SECRET=" "$ENVFILE" | cut -d'=' -f2- || true)
   if [[ "$current_val" != "$oauth2_proxy_secret" ]]; then
       if grep -q "^OAUTH2_PROXY_CLIENT_SECRET=" "$ENVFILE"; then
         sed -i "s|^OAUTH2_PROXY_CLIENT_SECRET=.*$|OAUTH2_PROXY_CLIENT_SECRET=${oauth2_proxy_secret}|g" "$ENVFILE"
       else
         echo "OAUTH2_PROXY_CLIENT_SECRET=${oauth2_proxy_secret}" >> "$ENVFILE"
       fi
       UPDATED_ENV=true
   fi
fi

for APP_INFO in $EXPECTED_APPS; do
   APP="${APP_INFO%%:*}"
   [[ "$APP" == "oauth2-proxy" ]] && continue
   secret_val=$(echo "$setup_output" | grep -i "^${APP}_OIDC_SECRET_VALUE=" | cut -d'=' -f2- || true)
   if [[ -n "$secret_val" ]] && [[ "$secret_val" != "No secret configured" ]]; then
      var_name=$(echo "${APP}_OIDC_SECRET" | tr '[:lower:]-' '[:upper:]_')
      current_val=$(grep "^${var_name}=" "$ENVFILE" | cut -d'=' -f2- || true)
      if [[ "$current_val" != "$secret_val" ]]; then
          if grep -q "^${var_name}=" "$ENVFILE"; then
            sed -i "s|^${var_name}=.*$|${var_name}=${secret_val}|g" "$ENVFILE"
          else
            echo "${var_name}=${secret_val}" >> "$ENVFILE"
          fi
          UPDATED_ENV=true
      fi
   fi
done

if [ "$UPDATED_ENV" = true ]; then
  echo "UPDATED_ENV"
fi
