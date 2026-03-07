#!/usr/bin/env bash
# sast-scan.sh: Run security scans against all stacks and repository.
# Usage: ./scripts/sast/sast-scan.sh [stack-name|all]

set -e

SCAN_TARGET=${1:-all}
STACKS_DIR="stacks"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# 1. Repository-wide Scans (Run only if target is 'all')
if [ "$SCAN_TARGET" == "all" ]; then
    echo ">>> Running repository-wide scans..."
    
    # Gitleaks: Secret detection
    if command -v gitleaks &> /dev/null; then
        echo ">>> Checking for secrets (Gitleaks)..."
        gitleaks detect --source "$REPO_ROOT" -v || echo "[WARNING] Gitleaks found potential secrets."
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
        checkov -d "$STACKS_DIR/$stack" --quiet --framework docker_compose || echo "[WARNING] Checkov found issues in $stack"
    fi
    
    # Trivy: Config & Image scan
    if command -v trivy &> /dev/null; then
        echo ">>> Vulnerability scanning (Trivy)..."
        trivy config "$STACKS_DIR/$stack" --quiet || echo "[WARNING] Trivy found config issues in $stack"
        # Optional: scan images referenced in compose
        # grep 'image:' "$STACKS_DIR/$stack/docker-compose.yml" | awk '{print $2}' | xargs -n1 trivy image --quiet || true
    fi

    # Semgrep: Targeted stack scan
    if command -v semgrep &> /dev/null; then
        echo ">>> Targeted analysis (Semgrep)..."
        semgrep --config auto --quiet "$STACKS_DIR/$stack" || echo "[WARNING] Semgrep found issues in $stack"
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
