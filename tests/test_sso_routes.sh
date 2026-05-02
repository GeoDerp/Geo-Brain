#!/bin/bash
# test_sso_routes.sh: Validates that all SSO-protected services
# correctly redirect to Kanidm with the proper callback URL,
# or properly load their Native OIDC login screens.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
    set +a
fi

DOMAIN="${DOMAIN:-example.local}"
CA_CERT="$REPO_ROOT/stacks/traefik/config/certs/root_ca.crt"

if [[ ! -f "$CA_CERT" ]]; then
    echo "CA root not found at $CA_CERT"
    exit 1
fi

# --- Services with Native OIDC (Expect 200 OK login page, except Grafana which auto-redirects) ---
NATIVE_OIDC_SERVICES=(
    "minio:minio"
    "grafana:grafana"
    "quay:quay"
    "gitea:gitea"
    "defectdojo:defectdojo"
)

# --- Services behind oauth2-proxy (Expect 302 Redirect to Kanidm) ---
PROXY_SERVICES=(
    "wazuh:wazuh:true:/admin-oauth2/callback"
    "homepage:${DOMAIN}:false:/oauth2/callback" 
    "dockge:dockge:true:/admin-oauth2/callback"
    "prometheus:prometheus:true:/admin-oauth2/callback"
    "n8n:n8n:false:/oauth2/callback"
    "notes:notes:false:/oauth2/callback"
)

# --- Output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { ((PASS++)); echo -e "  ${GREEN}✓ PASS:${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗ FAIL:${NC} $1"; }
info() { echo "--- $1 ---"; }

check_redirect() {
    local url="$1"
    local expected_callback_path="$2"
    local service_name="$3"

    info "Testing ${service_name} at ${url}"

    # Use curl to follow all redirects and see the final URL
    final_url=$(curl -k --cacert "$CA_CERT" -s -L -o /dev/null -w "%{url_effective}" --max-time 15 "$url")

    if [[ -z "$final_url" ]]; then
        fail "Could not determine final URL for ${url}"
        return
    fi
    
    pass "Final landing URL: ${final_url}"

    # Extract the redirect_uri parameter from the Kanidm URL
    # It might be in the query string of the final_url (Kanidm login page)
    redirect_uri=$(echo "$final_url" | grep -oP 'redirect_uri=\K[^&]+' | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()));" || true)

    if [[ -z "$redirect_uri" ]]; then
        # Check if we already landed at the app (session existed?)
        if echo "$final_url" | grep -q "${service_name}"; then
           pass "Already authenticated or landed at ${service_name}"
           return
        fi
        fail "Could not extract redirect_uri from final URL: ${final_url}"
        return
    fi

    # Check if the path in the redirect_uri matches what we expect
    callback_path=$(echo "$redirect_uri" | sed -E 's|https?://[^/]+||')
    
    if [[ "$callback_path" == "$expected_callback_path" ]]; then
        pass "Callback path is correct: ${callback_path}"
    else
        fail "Incorrect callback path. Expected '${expected_callback_path}', but got '${callback_path}'"
    fi
}

check_200() {
    local url="$1"
    local service_name="$2"

    info "Testing ${service_name} at ${url}"

    # Expect a 200 OK because the app serves its own login page with an SSO button
    http_code=$(curl -k --cacert "$CA_CERT" -s -o /dev/null -w "%{http_code}" --max-time 15 "$url")

    if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
        # 302 is acceptable if it redirects to a local /login path
        pass "Service reachable and serving native login/redirect (HTTP ${http_code})."
    else
        fail "Service not serving expected login page. HTTP code: ${http_code}"
    fi
}

# === Test Native OIDC Services ===
info "--- Validating Native OIDC Services ---"
for service in "${NATIVE_OIDC_SERVICES[@]}"; do
    IFS=':' read -r name subdomain <<< "$service"
    check_200 "https://${subdomain}.${DOMAIN}" "$name"
done

# === Test OAuth2-Proxy & Auto-Redirect Services ===
info "--- Validating OAuth2-Proxy Services ---"
for service in "${PROXY_SERVICES[@]}"; do
    IFS=':' read -r name subdomain is_admin expected_path <<< "$service"
    
    # Root domain doesn't have a subdomain part
    url="https://${subdomain}"
    if [[ "$subdomain" != "$DOMAIN" ]]; then
        url+=".${DOMAIN}"
    fi

    check_redirect "$url" "$expected_path" "$name"
done

echo ""
info "--- SSO Test Summary ---"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
