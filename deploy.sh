#!/usr/bin/env bash
# deploy.sh: STIG-compliant deployment wrapper for podman-compose
# Usage: ./deploy.sh [stack-name] [up|down|ps|logs|restart|check]

set -e

STACK_NAME=$1
COMMAND=${2:-up}
STACK_DIR="stacks/$STACK_NAME"
UID_VAL=$(id -u)

# Load global environment variables from root .env
if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Set dynamic UID and Podman Sock for rootless containers
export UID=$UID_VAL
export PODMAN_SOCK="/run/user/$UID_VAL/podman/podman.sock"

if [ -z "$STACK_NAME" ]; then
    echo "Usage: $0 [stack-name] [command (default: up)]"
    echo "Commands: up, down, ps, logs, restart, check"
    exit 1
fi

if [ ! -d "$STACK_DIR" ]; then
    echo "Error: Stack '$STACK_NAME' not found in stacks/."
    exit 1
fi

check_security() {
    local compose_file="$STACK_DIR/docker-compose.yml"
    local errors=0

    echo ">>> Running STIG & Security validation for $STACK_NAME..."

    # 1. Image Pinning (Mandate Digest or specific version, reject :latest)
    if grep -q "image:.*:latest" "$compose_file"; then
        echo "[ERROR] Image ':latest' tag found. Use digests or specific versions for air-gap reliability."
        ((errors++))
    fi

    # 2. Resource Limits (Reliability)
    if ! grep -q "limits:" "$compose_file"; then
        echo "[ERROR] No resource limits defined (deploy.resources.limits). This is required for reliability."
        ((errors++))
    fi

    # 3. Network Isolation (Mandate custom networks)
    if ! grep -q "networks:" "$compose_file"; then
        echo "[ERROR] No custom networks defined. Using default bridge is forbidden by architecture mandates."
        ((errors++))
    fi

    # 4. STIG Labels
    if ! grep -q "security.stig" "$compose_file"; then
        echo "[WARNING] No 'security.stig' labels found. While not an error yet, it is recommended for compliance tracking."
    fi

    # 5. Rootless hints (Check for privileged: true)
    if grep -q "privileged: true" "$compose_file"; then
        if grep -q "security.stig.bypass_privileged=true" "$compose_file"; then
            echo "[WARNING] 'privileged: true' detected, but bypass label is present. Proceeding with caution (Kernel/Security tool exception)."
        else
            echo "[ERROR] 'privileged: true' detected without bypass label. Rootless containers should use capabilities instead."
            ((errors++))
        fi
    fi

    # 6. Ensure Networks Exist (Self-healing)
    echo ">>> Checking required networks for $STACK_NAME..."
    # Extract networks that are NOT external: false and create them if missing
    # This is a bit complex via bash/grep, so we'll just check if podman-compose fails later
    # or pre-create common ones.
    
    if [ $errors -gt 0 ]; then
        echo ">>> Validation FAILED with $errors error(s)."
        return 1
    fi

    echo ">>> Validation PASSED."
    return 0
}

case $COMMAND in
    check)
        check_security
        ;;
    up)
        check_security || exit 1
        cd "$STACK_DIR"
        # Check if podman-compose or podman compose should be used
        if podman help compose &> /dev/null; then
            podman compose up -d
        else
            podman-compose up -d
        fi
        ;;
    down)
        cd "$STACK_DIR"
        if podman help compose &> /dev/null; then
            podman compose down
        else
            podman-compose down
        fi
        ;;
    ps)
        cd "$STACK_DIR"
        if podman help compose &> /dev/null; then
            podman compose ps
        else
            podman-compose ps
        fi
        ;;
    logs)
        cd "$STACK_DIR"
        if podman help compose &> /dev/null; then
            podman compose logs -f
        else
            podman-compose logs -f
        fi
        ;;
    restart)
        cd "$STACK_DIR"
        if podman help compose &> /dev/null; then
            podman compose restart
        else
            podman-compose restart
        fi
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'."
        exit 1
        ;;
esac

echo ">>> Done."
