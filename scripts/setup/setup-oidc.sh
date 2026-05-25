# Extract values from existing .env
BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENVFILE="$BASE_DIR/.env"
set -a; [ -f "$ENVFILE" ] && source "$ENVFILE"; set +a

if [[ -z "${KANIDM_ADMIN_PASSWORD:-}" ]]; then
  # Try to recover it
  KANIDM_ADMIN_PASSWORD=$(podman exec kanidm /sbin/kanidmd recover-account -c /data/server.toml idm_admin 2>/dev/null | grep new_password | grep -o '"[^"]*"' | tr -d '"' || true)
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
           # Read no_pkce flag: kanidm.oidc.no_pkce=true disables PKCE for apps that
           # don't send a code_challenge (e.g. Python/PHP OIDC libs, oauth2-proxy without
           # OAUTH2_PROXY_CODE_CHALLENGE_METHOD set). Apps that DO use PKCE (e.g. Gitea's
           # goth library) must NOT have this label — disabling PKCE causes Kanidm to
           # ignore the stored code_challenge, making the subsequent code_verifier check
           # fail with 401 Unauthorized.
           no_pkce=$(grep -oP 'kanidm\.oidc\.no_pkce=\K[^"]+' "$compose" | head -n 1 || echo "false")
           EXPECTED_APPS="$EXPECTED_APPS ${app_id}:${subdomain}:${redirect_path}:${no_pkce}"
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
    REST2="\${REST#*:}"
    REDIRECT_PATH="\${REST2%%:*}"
    NO_PKCE="\${REST2#*:}"
    
    ORIGIN_URL="https://\${SUBDOMAIN}.${DOMAIN}"
    REDIRECT_URL="\${ORIGIN_URL}\${REDIRECT_PATH}"

    kanidm system oauth2 create "\$APP" "\$APP OIDC" "\$ORIGIN_URL" -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 add-redirect-url "\$APP" "\$REDIRECT_URL" -C /tmp/ca.crt >/dev/null 2>&1 || true
    if [ "\$NO_PKCE" = "true" ]; then
        kanidm system oauth2 warning-insecure-client-disable-pkce "\$APP" -C /tmp/ca.crt >/dev/null 2>&1 || true
    fi
    
    kanidm system oauth2 delete-scope-map "\$APP" idm_all_persons -C /tmp/ca.crt >/dev/null 2>&1 || true
    kanidm system oauth2 update-scope-map "\$APP" stig_admins openid profile email groups -C /tmp/ca.crt >/dev/null 2>&1 || true
    if [ "\$APP" = "oauth2-proxy" ] || [ "\$APP" = "oauth2-proxy-admin" ]; then
        kanidm system oauth2 update-scope-map "\$APP" stig_users openid profile email groups -C /tmp/ca.crt >/dev/null 2>&1 || true
    fi
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

setup_output=$(echo "$payload" | podman run -i --rm --network host --env KANIDM_PASSWORD="${KANIDM_ADMIN_PASSWORD}" docker.io/kanidm/tools:1.10.2 sh 2>&1) || true

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
      if [[ "$APP" == "oauth2-proxy-admin" ]]; then
          var_name="OAUTH2_PROXY_ADMIN_OIDC_SECRET"
      else
          var_name=$(echo "${APP}_OIDC_SECRET" | tr '[:lower:]-' '[:upper:]_')
      fi
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
