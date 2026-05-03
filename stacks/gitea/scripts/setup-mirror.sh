#!/usr/bin/env bash
# setup-mirror.sh — Configure two-way mirroring for a Gitea repository.
# =======================================================================
# Creates a Gitea repo that:
#   1. Pulls from an upstream GitHub source (GitHub → Gitea, scheduled)
#   2. Has a push mirror configured (Gitea → GitHub, after merge to main)
#
# The PUSH direction is handled automatically by the mirror-sync.yml
# Gitea Action workflow (which runs after SAST passes). This script
# sets up the PULL direction (Gitea periodically pulls from GitHub).
#
# Usage:
#   export GITEA_URL=https://gitea.${DOMAIN}
#   export GITEA_TOKEN=<your-gitea-api-token>
#   export GITEA_ORG=<org or username in gitea>
#   export GITHUB_URL=https://github.com/user/repo.git
#   export GITHUB_PAT=<github-personal-access-token>  # for private repos
#   export REPO_NAME=<repository name to create in gitea>
#   bash setup-mirror.sh

set -euo pipefail

: "${GITEA_URL:?GITEA_URL must be set (e.g. https://gitea.your-domain.local)}"
: "${GITEA_TOKEN:?GITEA_TOKEN must be set (Gitea API token)}"
: "${GITEA_ORG:?GITEA_ORG must be set (Gitea org or username)}"
: "${GITHUB_URL:?GITHUB_URL must be set (upstream GitHub clone URL)}"
: "${REPO_NAME:?REPO_NAME must be set}"

GITHUB_PAT="${GITHUB_PAT:-}"   # optional — required for private repos

AUTH_HEADER="Authorization: token ${GITEA_TOKEN}"
API="${GITEA_URL}/api/v1"

echo "[mirror] Configuring two-way mirror for '${REPO_NAME}'"
echo "[mirror]   Pull source : ${GITHUB_URL}"
echo "[mirror]   Gitea org   : ${GITEA_ORG}"

# --- 1) Create the repository as a pull mirror ---
echo ""
echo "[mirror] Step 1: Creating pull mirror repository in Gitea..."
HTTP=$(curl -sf -o /tmp/mirror-create.json -w "%{http_code}" \
  -X POST "${API}/repos/migrate" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "{
    \"clone_addr\": \"${GITHUB_URL}\",
    \"repo_name\": \"${REPO_NAME}\",
    \"repo_owner\": \"${GITEA_ORG}\",
    \"mirror\": true,
    \"mirror_interval\": \"8h\",
    \"private\": false,
    \"auth_token\": \"${GITHUB_PAT}\",
    \"description\": \"Pull mirror of ${GITHUB_URL}\"
  }")

if [[ "$HTTP" == "201" ]]; then
  REPO_ID=$(jq -r '.id' /tmp/mirror-create.json)
  echo "[mirror] Pull mirror created (repo id=${REPO_ID})"
elif [[ "$HTTP" == "409" ]]; then
  echo "[mirror] Repository already exists — fetching existing repo id..."
  REPO_ID=$(curl -sf "${API}/repos/${GITEA_ORG}/${REPO_NAME}" \
    -H "${AUTH_HEADER}" | jq -r '.id')
  echo "[mirror] Using existing repo id=${REPO_ID}"
else
  echo "[mirror] ERROR: migrate returned HTTP ${HTTP}"
  cat /tmp/mirror-create.json
  exit 1
fi

# --- 2) Configure a push mirror (Gitea → GitHub) ---
# Note: the push mirror runs AFTER the mirror-sync.yml Gitea Action.
# This push mirror provides a fallback sync for direct admin pushes to Gitea.
if [[ -n "${GITHUB_PAT}" ]]; then
  echo ""
  echo "[mirror] Step 2: Configuring push mirror (Gitea → GitHub)..."
  PUSH_URL=$(echo "${GITHUB_URL}" | sed "s|https://|https://${GITHUB_PAT}@|")
  HTTP=$(curl -sf -o /tmp/mirror-push.json -w "%{http_code}" \
    -X POST "${API}/repos/${GITEA_ORG}/${REPO_NAME}/push_mirrors" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "{
      \"remote_address\": \"${PUSH_URL}\",
      \"remote_name\": \"github-upstream\",
      \"sync_on_commit\": false,
      \"interval\": \"0s\"
    }")
  if [[ "$HTTP" == "200" || "$HTTP" == "201" ]]; then
    echo "[mirror] Push mirror configured"
  else
    echo "[mirror] WARNING: push mirror setup returned HTTP ${HTTP} (may already exist)"
    cat /tmp/mirror-push.json 2>/dev/null || true
  fi
else
  echo "[mirror] Skipping push mirror — GITHUB_PAT not set"
fi

# --- 3) Seed the repo with CI/CD workflow files ---
echo ""
echo "[mirror] Step 3: Seeding repository with Gitea Action workflows..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/../workflows"

if [[ -d "${WORKFLOWS_DIR}" ]]; then
  for wf in "${WORKFLOWS_DIR}"/*.yml; do
    wf_name=$(basename "$wf")
    wf_content=$(base64 < "$wf" | tr -d '\n')
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST "${API}/repos/${GITEA_ORG}/${REPO_NAME}/contents/.gitea/workflows/${wf_name}" \
      -H "${AUTH_HEADER}" \
      -H "Content-Type: application/json" \
      -d "{
        \"message\": \"ci: seed ${wf_name} workflow template\",
        \"content\": \"${wf_content}\"
      }")
    if [[ "$HTTP" == "201" ]]; then
      echo "[mirror]   Seeded .gitea/workflows/${wf_name}"
    elif [[ "$HTTP" == "422" ]]; then
      echo "[mirror]   .gitea/workflows/${wf_name} already exists — skipped"
    else
      echo "[mirror]   WARNING: seeding ${wf_name} returned HTTP ${HTTP}"
    fi
  done
else
  echo "[mirror] No workflows/ directory found at ${WORKFLOWS_DIR} — skipping seed"
fi

echo ""
echo "[mirror] Done."
echo "[mirror] Pull mirror URL : ${GITEA_URL}/${GITEA_ORG}/${REPO_NAME}"
echo "[mirror] To trigger manual sync: curl -X POST ${API}/repos/${GITEA_ORG}/${REPO_NAME}/mirror-sync -H '${AUTH_HEADER}'"
