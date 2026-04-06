#!/usr/bin/env bash
# sast-scan.sh: Run security scans against all stacks and repository.
# Usage: ./scripts/sast/sast-scan.sh [stack-name|all]

set -e

SCAN_TARGET=${1:-all}
STACKS_DIR="stacks"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RESULTS_DIR="${REPO_ROOT}/.scan-results"
mkdir -p "$RESULTS_DIR"

# DefectDojo upload helper
DEFECTDOJO_URL="${DEFECTDOJO_URL:-http://localhost:8080}"
DEFECTDOJO_API_KEY="${DEFECTDOJO_API_KEY:-}"

upload_to_defectdojo() {
    local scan_type="$1"
    local file="$2"
    local engagement="${3:-1}"

    if [ -z "$DEFECTDOJO_API_KEY" ]; then
        echo "[SKIP] DEFECTDOJO_API_KEY not set — skipping upload for $scan_type"
        return 0
    fi

    if [ ! -f "$file" ]; then
        return 0
    fi

    echo ">>> Uploading $scan_type results to DefectDojo..."
    curl -s -X POST "${DEFECTDOJO_URL}/api/v2/import-scan/" \
        -H "Authorization: Token ${DEFECTDOJO_API_KEY}" \
        -F "scan_type=${scan_type}" \
        -F "file=@${file}" \
        -F "engagement=${engagement}" \
        -F "verified=false" \
        -F "active=true" \
        -F "close_old_findings=false" \
        || echo "[WARNING] Failed to upload $scan_type results to DefectDojo"
}

# 1. Repository-wide Scans (Run only if target is 'all')
if [ "$SCAN_TARGET" == "all" ]; then
    echo ">>> Running repository-wide scans..."
    
    # Gitleaks: Secret detection
    if command -v gitleaks &> /dev/null; then
        echo ">>> Checking for secrets (Gitleaks)..."
        gitleaks detect --source "$REPO_ROOT" -v --report-format json --report-path "$RESULTS_DIR/gitleaks.json" \
            || echo "[WARNING] Gitleaks found potential secrets."
        upload_to_defectdojo "Gitleaks Scan" "$RESULTS_DIR/gitleaks.json"
    fi

    # Semgrep: Code & Config Analysis
    if command -v semgrep &> /dev/null; then
        echo ">>> Static analysis (Semgrep)..."
        semgrep --config auto --quiet "$REPO_ROOT" || echo "[WARNING] Semgrep found potential issues."
    fi
fi

# 2. Per-stack Scans
scan_stack() {
    local stack=$1
    echo ">>> Scanning stack: $stack..."
    
    # Checkov: IaC scan
    if command -v checkov &> /dev/null; then
        echo ">>> Checking Infrastructure-as-Code (Checkov)..."
        checkov -d "$STACKS_DIR/$stack" --quiet --framework docker_compose \
            -o json > "$RESULTS_DIR/checkov-${stack}.json" 2>&1 \
            || echo "[WARNING] Checkov found issues in $stack"
        upload_to_defectdojo "Checkov Scan" "$RESULTS_DIR/checkov-${stack}.json"
    fi
    
    # Semgrep: Targeted stack scan
    if command -v semgrep &> /dev/null; then
        echo ">>> Targeted analysis (Semgrep)..."
        semgrep --config auto --quiet "$STACKS_DIR/$stack" || echo "[WARNING] Semgrep found issues in $stack"
    fi

    # Terrascan: IaC policy scan via OPA
    if command -v terrascan &> /dev/null; then
        echo ">>> Policy scanning (Terrascan)..."
        terrascan scan -i docker-compose -d "$STACKS_DIR/$stack" || echo "[WARNING] Terrascan found issues in $stack"
    fi

    # Grype + Dockle: Image-level scans (scan each image in the compose file)
    if command -v grype &> /dev/null || command -v dockle &> /dev/null; then
        while IFS= read -r img; do
            img=$(echo "$img" | xargs) # trim whitespace
            [ -z "$img" ] && continue

            if command -v grype &> /dev/null; then
                echo ">>> Image vulnerability scan (Grype): $img..."
                grype "$img" --quiet -o json > "$RESULTS_DIR/grype-${stack}-$(echo "$img" | tr '/:' '__').json" 2>&1 \
                    || echo "[WARNING] Grype found vulnerabilities in $img"
                upload_to_defectdojo "Anchore Grype" "$RESULTS_DIR/grype-${stack}-$(echo "$img" | tr '/:' '__').json"
            fi

            if command -v dockle &> /dev/null; then
                echo ">>> Image CIS lint (Dockle): $img..."
                dockle --exit-code 0 -f json -o "$RESULTS_DIR/dockle-${stack}-$(echo "$img" | tr '/:' '__').json" "$img" \
                    || echo "[WARNING] Dockle found issues in $img"
            fi
        done < <(grep 'image:' "$STACKS_DIR/$stack/docker-compose.yml" | sed 's/.*image:\s*//' | sed 's/#.*//')
    fi
}

if [ "$SCAN_TARGET" == "all" ]; then
    for stack_path in "$STACKS_DIR"/*/; do
        stack=$(basename "$stack_path")
        scan_stack "$stack"
    done
else
    if [ -d "$STACKS_DIR/$SCAN_TARGET" ]; then
        scan_stack "$SCAN_TARGET"
    else
        echo "Error: Stack '$SCAN_TARGET' not found."
        exit 1
    fi
fi

echo ">>> Scans complete."
