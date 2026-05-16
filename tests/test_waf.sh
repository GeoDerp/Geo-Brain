#!/bin/bash
# test_waf.sh: Verifies that the BunkerWeb WAF is actively blocking
# common malicious-looking payloads.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load .env for DOMAIN
if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
    set +a
fi

DOMAIN="${DOMAIN:-example.local}"
REMOTE_HOST="${REMOTE_HOST:-192.168.1.45}"
REMOTE_USER="${REMOTE_USER:-geo}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_debug}"
SSH_KEY_PATH="${SSH_KEY/#\~/$HOME}"
WAF_HOST="waf.${DOMAIN}"
# Rootless Podman binds port 8081 only to the host's local stack.
# Tests run via SSH so curl runs on the remote node where localhost:8081 is accessible.
# ModSecurity enforcement mode is On; 192.168.1.0/24 is NOT whitelisted.
WAF_DIRECT_URL="http://localhost:8081"

# Helper: run a single curl on the remote and return only the HTTP code
remote_waf_test() {
    local url="$1"
    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' -H 'Host: ${WAF_HOST}' '${url}'"
}

# --- Output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { ((PASS++)); echo -e "  ${GREEN}✓ PASS:${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗ FAIL:${NC} $1"; }

echo "--- Testing WAF at ${WAF_DIRECT_URL} via SSH (Host: ${WAF_HOST}) ---"

# Test 1: Basic SQL Injection
echo "[TEST] SQL Injection payload..."
# URL-encode quotes to avoid SSH shell quoting issues: ' = %27
http_code=$(remote_waf_test "${WAF_DIRECT_URL}/?id=1%27+OR+%271%27%3D%271")
if [[ "$http_code" == "403" || "$http_code" == "400" ]]; then
    pass "WAF blocked SQLi payload with HTTP $http_code"
else
    fail "WAF did not block SQLi payload (Expected 400/403, got $http_code)"
fi

# Test 2: Cross-Site Scripting (XSS)
echo "[TEST] XSS payload..."
http_code=$(remote_waf_test "${WAF_DIRECT_URL}/?q=%3Cscript%3Ealert%281%29%3C%2Fscript%3E")
if [[ "$http_code" == "403" || "$http_code" == "400" ]]; then
    pass "WAF blocked XSS payload with HTTP $http_code"
else
    fail "WAF did not block XSS payload (Expected 400/403, got $http_code)"
fi

# Test 3: Path Traversal
echo "[TEST] Path Traversal payload..."
http_code=$(remote_waf_test "${WAF_DIRECT_URL}/?file=..%2F..%2F..%2F..%2Fetc%2Fpasswd")
if [[ "$http_code" == "403" || "$http_code" == "400" ]]; then
    pass "WAF blocked Path Traversal payload with HTTP $http_code"
else
    fail "WAF did not block Path Traversal payload (Expected 400/403, got $http_code)"
fi

echo "--- Summary ---"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
exit $FAIL
