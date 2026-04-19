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
WAF_HOST="waf.${DOMAIN}"

# --- Output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { ((PASS++)); echo -e "  ${GREEN}✓ PASS:${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗ FAIL:${NC} $1"; }

echo "--- Testing WAF at https://${WAF_HOST} ---"

# Test 1: Basic SQL Injection
echo "[TEST] SQL Injection payload..."
http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${WAF_HOST}/?id=1' OR '1'='1'")
if [[ "$http_code" == "403" ]]; then
    pass "WAF blocked SQLi payload with HTTP 403"
else
    fail "WAF did not block SQLi payload (Expected 403, got $http_code)"
fi

# Test 2: Cross-Site Scripting (XSS)
echo "[TEST] XSS payload..."
http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${WAF_HOST}/?q=<script>alert(1)</script>")
if [[ "$http_code" == "403" ]]; then
    pass "WAF blocked XSS payload with HTTP 403"
else
    fail "WAF did not block XSS payload (Expected 403, got $http_code)"
fi

# Test 3: Path Traversal
echo "[TEST] Path Traversal payload..."
http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${WAF_HOST}/?file=../../../../etc/passwd")
if [[ "$http_code" == "403" ]]; then
    pass "WAF blocked Path Traversal payload with HTTP 403"
else
    fail "WAF did not block Path Traversal payload (Expected 403, got $http_code)"
fi

echo "--- Summary ---"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
exit $FAIL
