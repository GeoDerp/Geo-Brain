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

# --- Auto-discover services from compose labels ---
# Native OIDC: has kanidm.oidc.client_id label AND no oauth2-proxy middleware
NATIVE_OIDC_SERVICES=()
# ForwardAuth: has oauth2-proxy@file or oauth2-proxy-admin@file middleware
PROXY_SERVICES=()

while IFS= read -r compose; do
    has_client_id=$(grep -oP 'kanidm\.oidc\.client_id=\K[^"]+' "$compose" | head -n1 || true)
    has_proxy_mw=$(grep -l "oauth2-proxy@file\|oauth2-proxy-admin@file" "$compose" 2>/dev/null || true)
    has_admin_mw=$(grep -l "oauth2-proxy-admin@file" "$compose" 2>/dev/null || true)

    # Extract full hostname from Host() rule (everything between backticks)
    hostname=$(grep -oP 'traefik\.http\.routers\.[^.]+\.rule=Host\(`\K[^`]+' "$compose" | head -n1 || true)
    # Expand ${DOMAIN} placeholder that appears literally in compose label strings
    hostname="${hostname/\$\{DOMAIN\}/$DOMAIN}"
    # service name is stack dir basename
    svc_name=$(basename "$(dirname "$compose")")

    if [[ -n "$has_client_id" && -z "$has_proxy_mw" ]]; then
        # Skip oauth2-proxy container itself (it IS the auth proxy)
        [[ "$has_client_id" == oauth2-proxy* ]] && continue
        [[ -n "$hostname" ]] || continue
        NATIVE_OIDC_SERVICES+=("${has_client_id}:${hostname}")
    fi

    if [[ -n "$has_proxy_mw" ]]; then
        # Skip the oauth2-proxy stack itself
        grep -q 'kanidm\.oidc\.client_id=oauth2-proxy' "$compose" && continue
        [[ -n "$hostname" ]] || continue
        if [[ -n "$has_admin_mw" ]]; then
            PROXY_SERVICES+=("${svc_name}:${hostname}:true:/admin-oauth2/callback")
        else
            PROXY_SERVICES+=("${svc_name}:${hostname}:false:/oauth2/callback")
        fi
    fi
done < <(find "$REPO_ROOT/stacks" -not -path '*/_template/*' -type f -name "docker-compose.yml" | sort)

# --- Output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { ((PASS++)); echo -e "  ${GREEN}✓ PASS:${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗ FAIL:${NC} $1"; }
warn() { echo -e "  ${YELLOW}! WARN:${NC} $1"; }
info() { echo "--- $1 ---"; }

check_redirect() {
    local url="$1"
    local expected_callback_path="$2"
    local service_name="$3"

    info "Testing ${service_name} at ${url}"

    # Capture first redirect only — stops at first 3xx, avoids false-passes
    # from an active browser session that would follow all redirects to the app.
    http_response=$(curl --cacert "$CA_CERT" -s -i --max-redirs 0 --max-time 15 "$url" 2>&1 || true)
    http_code=$(echo "$http_response" | grep -m1 "^HTTP/" | awk '{print $2}')
    location=$(echo "$http_response" | grep -i "^Location:" | sed 's/^[Ll]ocation: //I' | tr -d '\r')

    if [[ "$http_code" != 30* ]]; then
        fail "Expected 3xx redirect from ForwardAuth, got HTTP $http_code"
        return
    fi

    if ! echo "$location" | grep -qE "kanidm\\.${DOMAIN}|/oauth2/start|/admin-oauth2/start"; then
        fail "First redirect does not point to auth endpoint: $location"
        return
    fi
    pass "ForwardAuth issues redirect (HTTP $http_code) toward auth"

    # Extract the redirect_uri parameter to verify the callback path
    redirect_uri=$(echo "$location" | grep -oP 'redirect_uri=\K[^& ]+' \
        | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || true)

    if [[ -z "$redirect_uri" ]]; then
        warn "redirect_uri not in first redirect (Kanidm may be the next hop) — skipping path check for ${service_name}"
        return
    fi

    callback_path=$(echo "$redirect_uri" | sed -E 's|https?://[^/]+||')
    if [[ "$callback_path" == "$expected_callback_path" ]]; then
        pass "Callback path correct: ${callback_path}"
    else
        fail "Expected '${expected_callback_path}', got '${callback_path}'"
    fi
}

check_200() {
    local url="$1"
    local service_name="$2"

    info "Testing ${service_name} at ${url}"

    # Expect a 200 OK because the app serves its own login page with an SSO button
    http_code=$(curl --cacert "$CA_CERT" -s -o /dev/null -w "%{http_code}" --max-time 15 "$url")

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
    IFS=':' read -r name hostname <<< "$service"
    check_200 "https://${hostname}" "$name"
done

# === Test OAuth2-Proxy & Auto-Redirect Services ===
info "--- Validating OAuth2-Proxy Services ---"
for service in "${PROXY_SERVICES[@]}"; do
    IFS=':' read -r name hostname is_admin expected_path <<< "$service"
    check_redirect "https://${hostname}" "$expected_path" "$name"
done

echo ""
info "--- SSO Test Summary ---"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
