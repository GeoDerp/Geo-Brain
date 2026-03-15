#!/usr/bin/env bash
# deploy.sh: STIG-compliant deployment wrapper for podman-compose.
# Supports local and remote (via podman remote + rsync + SSH) deployments.
# Usage: ./deploy.sh [stack-name|all|base|user] [up|down|ps|logs|restart|check]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK_NAME="$1"
COMMAND="${2:-up}"

# Track whether this script started an ssh-agent (for cleanup)
_SCRIPT_STARTED_AGENT=0

cleanup() {
    if [[ "$_SCRIPT_STARTED_AGENT" -eq 1 && -n "${SSH_AGENT_PID:-}" ]]; then
        kill "$SSH_AGENT_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Load global environment variables from root .env
if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
    set +a
fi

# --- SSH Agent / Passphrase Handling ---
# Ensures the SSH key is loaded into an agent so remote operations
# (podman --connection, rsync, SSH) work without repeated passphrase prompts.

ensure_ssh_agent() {
    [[ -z "${SSH_KEY:-}" ]] && return 0
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    if [[ ! -f "$SSH_KEY" ]]; then
        echo "[ERROR] SSH key not found: $SSH_KEY"
        exit 1
    fi

    if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l &>/dev/null 2>&1; then
        echo ">>> Starting ssh-agent..."
        eval "$(ssh-agent -s)" >/dev/null
        _SCRIPT_STARTED_AGENT=1
    fi

    # Compare by fingerprint (works even if ssh-add -l shows comment, not path)
    local key_fp
    key_fp=$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')
    if [[ -n "$key_fp" ]] && ssh-add -l 2>/dev/null | grep -qF "$key_fp"; then
        return 0
    fi

    echo ">>> Loading SSH key (enter passphrase if prompted)..."
    ssh-add "$SSH_KEY"
}

# Determine deployment mode (remote if REMOTE_HOST is set in .env)
if [[ -n "${REMOTE_HOST:-}" ]]; then
    DEPLOY_MODE="remote"
    ensure_ssh_agent
    PODMAN_CONNECTION="${PODMAN_CONNECTION:-homelab}"
    SSH_CMD=(ssh -o StrictHostKeyChecking=accept-new -i "${SSH_KEY}" -p "${SSH_PORT:-22}" "${REMOTE_USER}@${REMOTE_HOST}")
    REMOTE_BASE="${REMOTE_PROJECT_DIR:-brain-ssof}"
else
    DEPLOY_MODE="local"
    LOCAL_UID=$(id -u)
    export CONTAINER_UID="$LOCAL_UID"
    export PODMAN_SOCK="/run/user/${LOCAL_UID}/podman/podman.sock"
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

# --- Sync config to remote via rsync (host → homelab only) ---
# Transfers compose files and config directories. Excludes runtime data.

rsync_to_remote() {
    local stack_dir="$1"
    local rsync_ssh="ssh -i ${SSH_KEY} -p ${SSH_PORT:-22}"

    echo "    Syncing config → ${REMOTE_HOST}:~/${REMOTE_BASE}/${stack_dir}/"

    # Ensure remote directory exists
    "${SSH_CMD[@]}" "mkdir -p ~/${REMOTE_BASE}/${stack_dir}"

    # Sync stack config only (exclude runtime data)
    rsync -rlpt \
        -e "$rsync_ssh" \
        --exclude='data/' \
        --exclude='models/' \
        --exclude='*.log' \
        "$REPO_ROOT/${stack_dir}/" \
        "${REMOTE_USER}@${REMOTE_HOST}:~/${REMOTE_BASE}/${stack_dir}/"

    # Sync root .env to remote project base
    if [[ -f "$REPO_ROOT/.env" ]]; then
        rsync -lpt \
            -e "$rsync_ssh" \
            "$REPO_ROOT/.env" \
            "${REMOTE_USER}@${REMOTE_HOST}:~/${REMOTE_BASE}/.env"
    fi
}

# --- Ensure Remote Volume Directories ---
# Parses a compose file for bind-mount sources (./data, ./config, etc.)
# and creates the corresponding directories on the remote node.

ensure_remote_dirs() {
    local compose_file="$1"
    local stack_dir="$2"

    [[ ! -f "$compose_file" ]] && return 0

    local dirs=()

    # --- Handle relative volume paths (./something or ../something) ---
    local rel_paths
    rel_paths=$(grep -oP '^\s+-\s+\K\.\.?/[^:]+' "$compose_file" 2>/dev/null | sort -u) || true
    if [[ -n "$rel_paths" ]]; then
        while IFS= read -r p; do
            local local_src remote_rel
            if [[ "$p" == ../* ]]; then
                local_src="$REPO_ROOT/$stack_dir/$p"
                remote_rel=$(cd "$REPO_ROOT/$stack_dir" && realpath --relative-to="$REPO_ROOT" "$p" 2>/dev/null) || continue
                remote_rel="${REMOTE_BASE}/$remote_rel"
            else
                local_src="$REPO_ROOT/$stack_dir/${p#./}"
                remote_rel="${REMOTE_BASE}/${stack_dir}/${p#./}"
            fi
            if [[ -f "$local_src" ]]; then
                dirs+=("~/$(dirname "$remote_rel")")
            else
                dirs+=("~/$remote_rel")
            fi
        done <<< "$rel_paths"
    fi

    # --- Handle ${DATA_DIR}/... absolute volume paths ---
    local data_paths
    data_paths=$(grep -oP '^\s+-\s+\K\$\{DATA_DIR[^}]*\}/[^:]+' "$compose_file" 2>/dev/null | sort -u) || true
    if [[ -n "$data_paths" ]]; then
        local data_dir_val="${DATA_DIR:-/var/brain-ssof}"
        while IFS= read -r p; do
            # Expand ${DATA_DIR} or ${DATA_DIR:-default} to its value
            local expanded="${p/\$\{DATA_DIR\}/$data_dir_val}"
            expanded="${expanded/\$\{DATA_DIR:-*\}/$data_dir_val}"
            dirs+=("$expanded")
        done <<< "$data_paths"
    fi

    if [[ ${#dirs[@]} -gt 0 ]]; then
        local unique
        unique=$(printf '%s\n' "${dirs[@]}" | sort -u | tr '\n' ' ')
        echo "    Ensuring volume directories on remote..."
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "mkdir -p $unique"
    fi
}

# --- Execute compose on remote node via SSH ---

remote_compose() {
    local stack_dir="$1"
    local cmd="$2"
    shift 2
    local extra_args=("$@")
    # Shell-quote each arg for safe injection into the SSH command string
    local quoted_args=""
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        quoted_args=$(printf '%q ' "${extra_args[@]}")
    fi

    "${SSH_CMD[@]}" "
        cd ~/${REMOTE_BASE}/${stack_dir} || exit 1
        set -a; [ -f ~/${REMOTE_BASE}/.env ] && source ~/${REMOTE_BASE}/.env; set +a
        export CONTAINER_UID=\$(id -u)
        export PODMAN_SOCK=/run/user/\$(id -u)/podman/podman.sock
        if podman compose version &>/dev/null; then
            podman compose ${cmd} ${quoted_args}
        elif command -v podman-compose &>/dev/null; then
            podman-compose ${cmd} ${quoted_args}
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
    local cmd="$1"

    if [[ "$DEPLOY_MODE" == "remote" ]]; then
        if [[ "$cmd" == "up" || "$cmd" == "restart" ]]; then
            local compose_file="$REPO_ROOT/$stack_dir/docker-compose.yml"

            echo "  [1/3] Creating remote volume directories..."
            ensure_remote_dirs "$compose_file" "$stack_dir"

            echo "  [2/3] Syncing config to remote (rsync)..."
            rsync_to_remote "$stack_dir"

            echo "  [3/3] Running podman compose $cmd on remote..."
        else
            echo "  Running podman compose $cmd on remote..."
        fi
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

    # Extract network names where 'external: true' appears under the network
    local nets
    nets=$(awk '
        /^networks:/ { in_nets=1; next }
        in_nets && /^[^ ]/ { in_nets=0 }
        in_nets && /^  [a-zA-Z_-]/ {
            gsub(/:.*/, ""); gsub(/^[ ]+/, "")
            name=$0
            # Skip comment/blank lines to find external: true
            while ((getline line) > 0) {
                if (line ~ /^[[:space:]]*#/) continue
                if (line ~ /^[[:space:]]*$/) continue
                if (line ~ /external: *true/) print name
                break
            }
        }
    ' "$compose_file")

    [[ -z "$nets" ]] && return 0

    local missing=""
    for net in $nets; do
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            if ! "${SSH_CMD[@]}" "podman network exists '$net'" 2>/dev/null; then
                missing="${missing:+$missing }$net"
            fi
        else
            if ! podman network exists "$net" 2>/dev/null; then
                missing="${missing:+$missing }$net"
            fi
        fi
    done

    [[ -z "$missing" ]] && return 0

    echo "    Creating missing external networks for $stack_label:"
    for net in $missing; do
        echo "      + $net"
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            "${SSH_CMD[@]}" "podman network create --label security.stig.compliance=true '$net'" || true
        else
            podman network create --label "security.stig.compliance=true" "$net" || true
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
    if grep -qE 'image:.*:latest($|\s)' "$compose_file"; then
        echo "[ERROR] Image ':latest' tag found. Use digests or specific versions for air-gap reliability."
        errors=$((errors + 1))
    fi
    # Also flag untagged images (implicit :latest)
    if grep -qE '^\s+image:\s+[^:@]+\s*$' "$compose_file"; then
        echo "[ERROR] Untagged image found (implicit :latest). Pin to a specific version or digest."
        errors=$((errors + 1))
    fi

    # 2. Resource Limits (Reliability)
    if ! grep -q "limits:" "$compose_file"; then
        echo "[ERROR] No resource limits defined (deploy.resources.limits). This is required for reliability."
        errors=$((errors + 1))
    fi

    # 3. Network Isolation (Mandate custom networks)
    if ! grep -q "networks:" "$compose_file"; then
        echo "[ERROR] No custom networks defined. Using default bridge is forbidden by architecture mandates."
        errors=$((errors + 1))
    fi

    # 4. Healthcheck (Mandatory per GEMINI.md)
    if ! grep -q "healthcheck:" "$compose_file"; then
        echo "[ERROR] No healthcheck defined. Every service must define a healthcheck."
        errors=$((errors + 1))
    fi

    # 5. STIG Labels
    if ! grep -q "security.stig" "$compose_file"; then
        echo "[WARNING] No 'security.stig' labels found. While not an error yet, it is recommended for compliance tracking."
    fi

    # 6. Rootless hints (Check for privileged: true)
    if grep -q "privileged: true" "$compose_file"; then
        if grep -q "security.stig.bypass_privileged=true" "$compose_file"; then
            echo "[WARNING] 'privileged: true' detected, but bypass label is present. Proceeding with caution (Kernel/Security tool exception)."
        else
            echo "[ERROR] 'privileged: true' detected without bypass label. Rootless containers should use capabilities instead."
            errors=$((errors + 1))
        fi
    fi

    # 7. Ensure Networks Exist (Self-healing)
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
