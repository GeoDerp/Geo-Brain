#!/bin/bash
# test_cicd.sh: End-to-end test for the DevSecOps pipeline.
# 1. Creates a temporary repo in Gitea.
# 2. Pushes a file with a dummy secret.
# 3. Waits for the Gitea Action to trigger a SAST scan.
# 4. Polls DefectDojo to verify a new "High" severity finding is created.
# 5. Cleans up the repo and finding.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load .env for credentials and domain
if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
    set +a
fi

DOMAIN="${DOMAIN:-example.local}"
GITEA_URL="https://gitea.${DOMAIN}"
DOJO_URL="https://defectdojo.${DOMAIN}"

# Credentials (ensure these are set in .env)
GITEA_TOKEN="${GITEA_ADMIN_TOKEN}" # Needs an admin token with repo creation permissions
DOJO_API_KEY="${DEFECTDOJO_API_KEY}" # Needs an API key for a user with product access

REPO_NAME="test-cicd-repo-${RANDOM}"
DUMMY_SECRET="DUMMY_GEO_BRAIN_SECRET_KEY=a1b2c3d4e5f67890a1b2c3d4e5f67890"

# --- Output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
pass() { echo -e "  ${GREEN}✓ PASS:${NC} $1"; }
fail() { echo -e "  ${RED}✗ FAIL:${NC} $1"; exit 1; }
info() { echo "  [INFO] $1"; }

# --- Cleanup ---
cleanup() {
    info "--- Running Cleanup ---"
    # Delete Gitea repo
    curl -k -s -X DELETE -H "Authorization: token ${GITEA_TOKEN}" 
        "${GITEA_URL}/api/v1/repos/gitea_admin/${REPO_NAME}" >/dev/null
    info "Deleted Gitea repo ${REPO_NAME}"

    # Optionally, delete finding from DefectDojo (requires finding ID)
    # This is more complex and can be added later.
}
trap cleanup EXIT

# --- Main Test ---

info "--- 1. Creating Gitea repository ---"
repo_response=$(curl -k -s -X POST -H "Content-Type: application/json" -H "Authorization: token ${GITEA_TOKEN}" 
    -d "{"name":"${REPO_NAME}","private":false,"auto_init":true}" 
    "${GITEA_URL}/api/v1/user/repos")
clone_url=$(echo "$repo_response" | grep -oP '"clone_url":\s*"\K[^"]+')
if [[ -z "$clone_url" ]]; then
    fail "Could not create Gitea repo. Response: $repo_response"
fi
pass "Created Gitea repo: ${clone_url}"

info "--- 2. Pushing file with dummy secret ---"
git clone "$clone_url" "/tmp/${REPO_NAME}"
echo "$DUMMY_SECRET" > "/tmp/${REPO_NAME}/secrets.txt"
cd "/tmp/${REPO_NAME}"
git config --global user.email "tester@example.com"
git config --global user.name "CI/CD Tester"
git add secrets.txt
git commit -m "Add dummy secret for testing"
git push origin main
cd "$REPO_ROOT"
rm -rf "/tmp/${REPO_NAME}"
pass "Pushed commit with dummy secret"

info "--- 3. Waiting for SAST scan and DefectDojo finding ---"
info "(This may take a few minutes for the Gitea Action runner to pick up the job)"

for i in {1..30}; do
    echo -n "."
    # Search for a high-severity finding related to our commit
    findings=$(curl -k -s -X GET -H "Authorization: Token ${DOJO_API_KEY}" 
        "${DOJO_URL}/api/v2/findings/?title=Hard-coded+secret&severity=High&active=true")
    
    if echo "$findings" | grep -q "$DUMMY_SECRET"; then
        pass "DefectDojo created a finding for the dummy secret!"
        # TODO: Add cleanup of the finding here if API allows
        exit 0
    fi
    sleep 10
done

fail "Timed out waiting for DefectDojo finding to be created."
