#!/usr/bin/env bash
# deploy.sh: STIG-compliant deployment wrapper for podman-compose.
# Supports local and remote (via SSH) deployments.
# Usage: ./deploy.sh [stack-name|all|base|user] [up|down|ps|logs|restart|check]

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK_NAME="$1"
COMMAND="${2:-up}"

# Load global environment variables from root .env
if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
    set +a
fi

# Determine deployment mode (remote if init-node.sh has been run)
if [[ -n "${REMOTE_HOST:-}" ]]; then
    DEPLOY_MODE="remote"
    SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -i ${SSH_KEY} -p ${SSH_PORT:-22}"
    SSH_CMD="ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST}"
    REMOTE_BASE="${REMOTE_PROJECT_DIR:-brain-ssof}"
else
    DEPLOY_MODE="local"
    export CONTAINER_UID=$(id -u)
    export PODMAN_SOCK="/run/user/$(id -u)/podman/podman.sock"
fi

if [ -z "$STACK_NAME" ]; then
    echo "Usage: $0 [stack-name|all|base|user] [command (default: up)]"
    echo "Commands: up, down, ps, logs, restart, check"
    echo "Mode: ${DEPLOY_MODE}"
    echo ""
    echo "Special targets:"
    echo "  all   - Deploy all stacks (base + user)"
    echo "  base  - Deploy all base infrastructure stacks"
    echo "  user  - Deploy all user application stacks"
    exit 1
fi

# --- Stack Discovery ---

get_base_stacks() {
    for dir in "$REPO_ROOT"/stacks/*/; do
        local name
        name="$(basename "$dir")"
        [[ "$name" == "_template" || "$name" == "user" ]] && continue
        echo "$name"
    done
}

get_user_stacks() {
    for dir in "$REPO_ROOT"/stacks/user/*/; do
        [ -d "$dir" ] || continue
        echo "user/$(basename "$dir")"
    done
}

get_all_stacks() {
    get_base_stacks
    get_user_stacks
}

# --- Sync stack files to remote node via tar-over-SSH ---

sync_to_remote() {
    local stack_dir="$1"
    echo ">>> Syncing '$stack_dir' to ${REMOTE_USER}@${REMOTE_HOST}..."
    $SSH_CMD "mkdir -p ~/${REMOTE_BASE}/${stack_dir}"

    local tar_args=("${stack_dir}")
    [[ -f "$REPO_ROOT/.env" ]] && tar_args+=(".env")

    tar -cf - -C "$REPO_ROOT" "${tar_args[@]}" | \
        $SSH_CMD "tar -xf - -C ~/${REMOTE_BASE}/"
}

# --- Execute compose on remote node via SSH ---

remote_compose() {
    local stack_dir="$1"
    local cmd="$2"
    shift 2
    local extra_args="$*"

    $SSH_CMD "
        cd ~/${REMOTE_BASE}/${stack_dir} || exit 1
        set -a; [ -f ../../.env ] && source ../../.env; set +a
        export CONTAINER_UID=\$(id -u)
        export PODMAN_SOCK=/run/user/\$(id -u)/podman/podman.sock
        if podman compose version &>/dev/null; then
            podman compose ${cmd} ${extra_args}
        elif command -v podman-compose &>/dev/null; then
            podman-compose ${cmd} ${extra_args}
        else
            echo '[ERROR] No compose tool found on remote.'
            exit 1
        fi
    "
}

# --- Execute compose locally ---

local_compose() {
    local stack_dir="$1"
    local cmd="$2"
    shift 2
    local extra_args=("$@")

    cd "$REPO_ROOT/$stack_dir"
    if podman compose version &> /dev/null; then
        podman compose "$cmd" "${extra_args[@]}"
    elif command -v podman-compose &> /dev/null; then
        podman-compose "$cmd" "${extra_args[@]}"
    else
        echo "[ERROR] Neither 'podman compose' nor 'podman-compose' found."
        exit 1
    fi
    cd "$REPO_ROOT"
}

# --- Unified compose runner ---

run_compose() {
    local stack_dir="$1"
    shift

    if [[ "$DEPLOY_MODE" == "remote" ]]; then
        sync_to_remote "$stack_dir"
        remote_compose "$stack_dir" "$@"
    else
        local_compose "$stack_dir" "$@"
    fi
}

# --- Ensure External Networks Exist ---
# Parses a docker-compose.yml for 'external: true' networks and creates
# any that don't exist yet. Runs locally or on the remote node.

ensure_networks() {
    local compose_file="$1"
    local stack_label="$2"

    [[ ! -f "$compose_file" ]] && return 0

    # Extract network names where the next non-blank line is 'external: true'
    local nets
    nets=$(awk '
        /^networks:/ { in_nets=1; next }
        in_nets && /^[^ ]/ { in_nets=0 }
        in_nets && /^  [a-zA-Z]/ {
            gsub(/:.*/, ""); gsub(/^[ ]+/, "")
            name=$0
            getline
            if ($0 ~ /external: *true/) print name
        }
    ' "$compose_file")

    [[ -z "$nets" ]] && return 0

    local missing=""
    for net in $nets; do
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            if ! $SSH_CMD "podman network exists $net" 2>/dev/null; then
                missing="${missing:+$missing }$net"
            fi
        else
            if ! podman network exists "$net" 2>/dev/null; then
                missing="${missing:+$missing }$net"
            fi
        fi
    done

    [[ -z "$missing" ]] && return 0

    echo ">>> Creating missing external networks for $stack_label:"
    for net in $missing; do
        echo "    + $net"
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            $SSH_CMD "podman network create --label security.stig.compliance=true $net"
        else
            podman network create --label "security.stig.compliance=true" "$net"
        fi
    done
}

# --- Security Check ---

check_security() {
    local stack_dir="$1"
    local compose_file="$stack_dir/docker-compose.yml"
    local stack_label="$2"
    local errors=0

    echo ">>> Running STIG & Security validation for $stack_label..."

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
    ensure_networks "$compose_file" "$stack_label"
    
    if [ $errors -gt 0 ]; then
        echo ">>> Validation FAILED with $errors error(s)."
        return 1
    fi

    echo ">>> Validation PASSED."
    return 0
}

# --- Single Stack Execution ---

deploy_single() {
    local stack_name="$1"
    local stack_dir="stacks/$stack_name"

    if [ ! -d "$REPO_ROOT/$stack_dir" ]; then
        echo "Error: Stack '$stack_name' not found in stacks/."
        exit 1
    fi

    case $COMMAND in
        check)
            check_security "$REPO_ROOT/$stack_dir" "$stack_name"
            return $?
            ;;
        up)
            check_security "$REPO_ROOT/$stack_dir" "$stack_name" || return 1
            run_compose "$stack_dir" "up" "-d"
            ;;
        down)    run_compose "$stack_dir" "down" ;;
        ps)      run_compose "$stack_dir" "ps" ;;
        logs)    run_compose "$stack_dir" "logs" "-f" ;;
        restart) run_compose "$stack_dir" "restart" ;;
        *)
            echo "[ERROR] Unknown command '$COMMAND'."
            echo "Valid: up, down, ps, logs, restart, check"
            exit 1
            ;;
    esac
}

# --- Batch Stack Execution ---

deploy_batch() {
    local stacks=("$@")
    local failed=()

    # logs -f doesn't make sense for batch operations
    if [[ "$COMMAND" == "logs" ]]; then
        echo "Error: 'logs' command is not supported for batch targets. Use a specific stack name."
        exit 1
    fi

    echo ">>> Batch $COMMAND for ${#stacks[@]} stack(s)..."
    echo ""

    for stack in "${stacks[@]}"; do
        echo "=== [$stack] ==="
        if ! deploy_single "$stack"; then
            failed+=("$stack")
            echo "[FAILED] $stack"
        fi
        echo ""
    done

    if [ ${#failed[@]} -gt 0 ]; then
        echo ">>> Batch $COMMAND completed with ${#failed[@]} failure(s): ${failed[*]}"
        exit 1
    fi

    echo ">>> Batch $COMMAND completed successfully for all ${#stacks[@]} stack(s)."
}

# --- Main ---

case $STACK_NAME in
    all)
        mapfile -t stacks < <(get_all_stacks)
        deploy_batch "${stacks[@]}"
        ;;
    base)
        mapfile -t stacks < <(get_base_stacks)
        deploy_batch "${stacks[@]}"
        ;;
    user)
        mapfile -t stacks < <(get_user_stacks)
        deploy_batch "${stacks[@]}"
        ;;
    *)
        deploy_single "$STACK_NAME"
        echo ">>> Done."
        ;;
esac
