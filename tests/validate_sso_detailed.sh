#!/usr/bin/env bash
# validate_sso_detailed.sh: Deep validation of OIDC configuration across all STIG-Homelab stacks.
# Checks: Discovery endpoints, Redirection logic, Client ID matching, and Redirect URI registration.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

DOMAIN="${DOMAIN:-example.local}"
CA_CERT="$REPO_ROOT/stacks/traefik/config/certs/root_ca.crt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓ PASS:${NC} $1"; }
fail() { echo -e "  ${RED}✗ FAIL:${NC} $1"; ((FAIL_COUNT++)); }
warn() { echo -e "  ${YELLOW}! WARN:${NC} $1"; }
info() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

FAIL_COUNT=0

# --- 1. Validate OIDC Discovery Endpoints ---
# These must return valid JSON with the correct issuer.
info "1. Validating OIDC Discovery Endpoints"

# Auto-discover all registered OIDC clients from compose labels
DISCOVERY_APPS=()
while IFS= read -r compose; do
    while IFS= read -r client_id; do
        [[ -z "$client_id" ]] && continue
        DISCOVERY_APPS+=("${client_id}:https://kanidm.${DOMAIN}/oauth2/openid/${client_id}/.well-known/openid-configuration")
    done < <(grep -oP 'kanidm\.oidc\.client_id=\K[^"]+' "$compose" 2>/dev/null || true)
done < <(find "$REPO_ROOT/stacks" -not -path '*/_template/*' -type f -name "docker-compose.yml" | sort)

for app_info in "${DISCOVERY_APPS[@]}"; do
    app="${app_info%%:*}"
    url="${app_info#*:}"
    
    echo "Testing discovery for $app..."
    resp=$(curl -s -k -f "$url" || echo "FAILED")
    if [[ "$resp" == "FAILED" ]]; then
        fail "[$app] Discovery endpoint unreachable: $url"
    elif ! echo "$resp" | grep -q '"issuer"'; then
        fail "[$app] Discovery returned invalid JSON or missing issuer: $resp"
    else
        issuer=$(echo "$resp" | grep -oP '"issuer":"\K[^"]+')
        pass "[$app] Discovery OK. Issuer: $issuer"
    fi
done

# --- 2. Validate Redirection & Client Parameters ---
# We simulate a hit to the app and check how it sends the user to Kanidm.
info "2. Validating Application Redirection Logic"

# Core oauth2-proxy tests are always included
TEST_CASES=(
    "oauth2-proxy|https://auth.${DOMAIN}/oauth2/start|client_id=oauth2-proxy"
    "oauth2-proxy-admin|https://auth.${DOMAIN}/admin-oauth2/start|client_id=oauth2-proxy-admin"
)
# Auto-discover ForwardAuth-protected services
while IFS= read -r compose; do
    has_proxy=$(grep -l "oauth2-proxy-admin@file\|oauth2-proxy@file" "$compose" 2>/dev/null || true)
    [[ -z "$has_proxy" ]] && continue
    grep -q 'kanidm\.oidc\.client_id=oauth2-proxy' "$compose" && continue
    hostname=$(grep -oP 'traefik\.http\.routers\.[^.]+\.rule=Host\(`\K[^`]+' "$compose" | head -n1 || true)
    [[ -z "$hostname" ]] && continue
    if grep -q "oauth2-proxy-admin@file" "$compose"; then
        client="oauth2-proxy-admin"
    else
        client="oauth2-proxy"
    fi
    svc_name=$(basename "$(dirname "$compose")")
    TEST_CASES+=("${svc_name}|https://${hostname}|client_id=${client}")
done < <(find "$REPO_ROOT/stacks" -not -path '*/_template/*' -type f -name "docker-compose.yml" | sort)

for test_case in "${TEST_CASES[@]}"; do
    IFS='|' read -r app url params <<< "$test_case"
    
    echo "Testing redirection for $app at $url..."
    # Get the final location after all redirects
    location=$(curl -s -k -L -o /dev/null -w "%{url_effective}" "$url")
    
    if [[ "$location" != *"kanidm.${DOMAIN}"* ]]; then
        fail "[$app] No redirect to Kanidm received from $url (Landed at: $location)"
        continue
    fi

    # Check if redirect contains expected client_id
    if echo "$location" | grep -q "$params"; then
        pass "[$app] Redirect parameters correct ($params)"
    else
        fail "[$app] Redirect missing or wrong parameters. Got: $location"
    fi

    # Check for invalid origin indicator (common OIDC error we saw in logs)
    if echo "$location" | grep -q "error=invalid_origin"; then
        fail "[$app] Kanidm rejected redirect_uri (invalid_origin error)"
    elif echo "$location" | grep -q "unrecoverable_error"; then
        fail "[$app] Kanidm reported an unrecoverable error"
    fi
done

# --- 3. Validate Kanidm Log Integrity (Optional/Remote) ---
info "3. Final Integration Check"
echo "To confirm absolute 100% certainty, check Kanidm logs for 'invalid_origin' or 'invalid_request' after clicking login buttons."
echo "Command: podman logs kanidm 2>&1 | grep -iE 'error|warn' | grep -i 'oauth2'"

if (( FAIL_COUNT > 0 )); then
    echo -e "\n${RED}${BOLD}❌ SSO Validation Failed with $FAIL_COUNT errors.${NC}"
    exit 1
else
    echo -e "\n${GREEN}${BOLD}✅ SSO Validation Successful! All OIDC discovery and redirection logic is verified.${NC}"
    exit 0
fi
