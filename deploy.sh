#!/usr/bin/env bash
# @GEMINI.md: Single Source of Truth for this script's mandates.
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
        echo ">>> Cleaning up temporary ssh-agent (PID: $SSH_AGENT_PID)..."
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

# Expand tilde in DATA_DIR and SSH_KEY if they exist
DATA_DIR="${DATA_DIR:-/var/My-HomeLab}"
DATA_DIR="${DATA_DIR/#\~/$HOME}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

# Auto-detect Podman default network subnet (for services that need to trust the proxy IP)
if [[ -z "${PODMAN_SUBNET:-}" ]]; then
    _detected=$(podman network inspect podman --format '{{range .Subnets}}{{.Subnet}}{{end}}' 2>/dev/null | head -n1 || true)
    if [[ -n "$_detected" ]]; then
        export PODMAN_SUBNET="$_detected"
    fi
fi

# Validate that critical environment variables are set before deploying
validate_env() {
    local errors=0
    local REQUIRED_VARS=(DOMAIN ADMIN_PASSWORD MINIO_ROOT_PASSWORD QUAY_DB_PASSWORD CLAIR_DB_PASSWORD DEFECTDOJO_DB_PASSWORD)
    for var in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "[ERROR] Required variable \$$var is not set. Add it to .env"
            (( errors++ )) || true
        fi
    done
    # Warn on known-weak defaults
    local WEAK_DEFAULTS=(moodle123! changeme123! minioadmin password admin)
    for var in MOODLE_DB_PASSWORD MOODLE_ADMIN_PASSWORD MINIO_ROOT_PASSWORD ADMIN_PASSWORD; do
        val="${!var:-}"
        for weak in "${WEAK_DEFAULTS[@]}"; do
            if [[ "$val" == "$weak" ]]; then
                echo "[WARNING] \$$var is set to a known-weak default value: '$val'"
            fi
        done
    done
    if (( errors > 0 )); then
        echo ""
        echo "Copy .env.example to .env and fill in the required values."
        exit 1
    fi
}

if [[ "$COMMAND" == "up" || "$COMMAND" == "redeploy" ]]; then
    validate_env
fi

if [[ "$COMMAND" == "up" ]]; then
    if [[ ! -f "$REPO_ROOT/certs/ca.crt" ]] || [[ ! -f "$REPO_ROOT/certs/wildcard.crt" ]]; then
        echo -e "\n[WARNING] Missing core certificates (ca.crt or wildcard.crt) in $REPO_ROOT/certs/."
        echo "Did you forget to run: ./scripts/secrets/gen-selfsigned-certs.sh ?"
        echo -n "Press ENTER to continue anyway, or Ctrl+C to abort..."
        read -r
    fi
fi

# --- SSH Agent / Passphrase Handling ---
# Ensures the SSH key is loaded into an agent so remote operations
# (podman --connection, rsync, SSH) work without repeated passphrase prompts.

ensure_ssh_agent() {
    [[ -z "${SSH_KEY:-}" ]] && return 0
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
    REMOTE_BASE="${REMOTE_PROJECT_DIR:-My-HomeLab}"
else
    DEPLOY_MODE="local"
    LOCAL_UID=$(id -u)
    export CONTAINER_UID="$LOCAL_UID"
    export PODMAN_SOCK="/run/user/${LOCAL_UID}/podman/podman.sock"
fi

if [ -z "$STACK_NAME" ]; then
    echo "Usage: $0 [stack-name|all|base|user] [command (default: up)]"
    echo "Commands: up, down, ps, logs, restart, check, redeploy"
    echo "Mode: ${DEPLOY_MODE}"
    echo ""
    echo "Special targets:"
    echo "  all   - Deploy all stacks (base + user, excludes cicd)"
    echo "  base  - Deploy all base infrastructure stacks"
    echo "  user  - Deploy all user application stacks"
    echo "  cicd  - Deploy CI/CD pipeline (gitea + defectdojo [+ ramalama if GPU found])"
    exit 1
fi

# --- GPU Detection ---
# Probes the target host for discrete GPU devices.
# Returns: "nvidia", "amd", or "none"
detect_remote_gpu() {
    local result="none"
    if [[ "$DEPLOY_MODE" == "remote" ]]; then
        if "${SSH_CMD[@]}" 'ls /dev/nvidia0 2>/dev/null | grep -q nvidia0' 2>/dev/null; then
            result="nvidia"
        elif "${SSH_CMD[@]}" 'ls /dev/dri/renderD128 2>/dev/null | grep -q renderD' 2>/dev/null; then
            result="amd"
        fi
    else
        if ls /dev/nvidia0 2>/dev/null | grep -q nvidia0; then
            result="nvidia"
        elif ls /dev/dri/renderD128 2>/dev/null | grep -q renderD; then
            result="amd"
        fi
    fi
    echo "$result"
}

# --- Stack Discovery ---

get_base_stacks() {
    local ordered_stacks=(
        "step-ca"
        "traefik"
        "bunkerweb"
        "pangolin"
        "kanidm"
        "oauth2-proxy"
        "seaweedfs"
        "loki"
        "vector"
        "prometheus"
        "wazuh"
        "falco"
        "crowdsec"
        "quay"
        "defectdojo"
        "gitea"
        "ramalama"
        "grafana"
        "dockge"
        "homepage"
    )

    # CI/CD pipeline stacks (gitea + defectdojo + ramalama) are optional;
    # deploy them together via: ./deploy.sh cicd up
    local exclude_stacks=("prometheus" "gitea" "defectdojo" "ramalama")
    local found_stacks=()
    for dir in "$REPO_ROOT"/stacks/*/; do
        local name
        name="$(basename "$dir")"
        [[ "$name" == "_template" || "$name" == "user" ]] && continue
        
        # Skip excluded stacks
        local skip=0
        for ex in "${exclude_stacks[@]}"; do
            if [[ "$name" == "$ex" ]]; then skip=1; break; fi
        done
        [[ "$skip" -eq 1 ]] && continue
        if [[ -f "$dir/docker-compose.yml" ]] && ! grep -q '^[[:space:]]*services:' "$dir/docker-compose.yml"; then
            continue
        fi
        found_stacks+=("$name")
    done

    # Output in the specified order
    for stack in "${ordered_stacks[@]}"; do
        for i in "${!found_stacks[@]}"; do
            if [[ "${found_stacks[$i]}" == "$stack" ]]; then
                echo "$stack"
                unset 'found_stacks[i]'
                break
            fi
        done
    done

    # Output any remaining stacks not in the hardcoded list
    for stack in "${found_stacks[@]}"; do
        echo "$stack"
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
    # Also include cicd stacks for full coverage
    for dir in "$REPO_ROOT"/stacks/*/; do
        local name=$(basename "$dir")
        if [[ "$name" == "gitea" || "$name" == "defectdojo" || "$name" == "prometheus" ]]; then
             echo "$name"
        fi
    done | sort -u
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
        export STACKS_PATH=\"\$HOME/${REMOTE_BASE}/stacks\"
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
    export STACKS_PATH="$REPO_ROOT/stacks"
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
        echo "  Running podman compose $cmd on remote..."
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

    echo ">>> Running STIG & Security validation for $stack_label..."
    if ! python3 "$REPO_ROOT/scripts/analysis/validate_stacks.py" "$compose_file"; then
        return 1
    fi

    # 7. Ensure Networks Exist (Self-healing)
    ensure_networks "$compose_file" "$stack_label"

    echo ">>> Validation PASSED."
    return 0
}

# --- TRAEFIK DYNAMIC CONFIG GENERATOR ---

cleanup_traefik_configs() {
    local stack_filter="${1:-}"
    local gen_dir="$REPO_ROOT/stacks/traefik/config/dynamic"
    
    if [[ -z "$stack_filter" ]]; then
        echo ">>> Cleaning up all old generated Traefik configs..."
        rm -f "$gen_dir"/gen_*.yml
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            "${SSH_CMD[@]}" "rm -f ~/${REMOTE_BASE}/stacks/traefik/config/dynamic/gen_*.yml"
        fi
    else
        local filter_name="${stack_filter/\//_}"
        echo ">>> Cleaning up old generated Traefik config for $stack_filter..."
        rm -f "$gen_dir"/gen_"${filter_name}"_*.yml
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            "${SSH_CMD[@]}" "rm -f ~/${REMOTE_BASE}/stacks/traefik/config/dynamic/gen_${filter_name}_*.yml"
        fi
    fi
}

generate_traefik_config() {
    local stack_name="$1"
    local stack_dir="stacks/$stack_name"
    local compose_file="$REPO_ROOT/$stack_dir/docker-compose.yml"
    local rel_gen_dir="stacks/traefik/config/dynamic"
    local gen_dir="$REPO_ROOT/$rel_gen_dir"
    
    # Only generate if the stack has Traefik labels
    if ! grep -q "traefik.enable=true" "$compose_file"; then
        return 0
    fi

    # Extract the service name that has Traefik labels (use awk to find
    # the nearest top-level service definition above "traefik.enable=true")
    local service_name
    service_name=$(awk '/^  [a-zA-Z0-9_-]+:/{svc=$1} /traefik\.enable=true/{gsub(/:$/,"",svc); print svc; exit}' "$compose_file" | xargs)
    [[ -z "$service_name" ]] && service_name="${stack_name##*/}"

    local filename="gen_${stack_name/\//_}_${service_name}.yml"
    local output_file="$gen_dir/$filename"

    mkdir -p "$gen_dir"

    # Use the service name as the subdomain if not explicitly overridden by labels
    local rule="Host(\`${service_name}.${DOMAIN}\`)"
    if grep -q "traefik.http.routers.*.rule" "$compose_file"; then
        local raw_rule=$(grep "traefik.http.routers.*.rule" "$compose_file" | sed -E 's/.*rule="?([^"]+)"?/\1/' | head -n 1)
        rule=$(echo "$raw_rule" | sed "s/\${DOMAIN}/${DOMAIN}/g" | sed "s/\$DOMAIN/${DOMAIN}/g" | sed "s/{{DOMAIN}}/${DOMAIN}/g" | sed 's/\$\$/$/g' | sed 's/\\\\/\\/g')
    fi
    
    local port=$(grep "traefik.http.services.*.port" "$compose_file" | sed -E 's/.*port[=:]"?([0-9]+)"?.*/\1/' | head -n 1)
    local priority=$(grep "traefik.http.routers.*.priority" "$compose_file" | sed -E 's/.*priority[=:]"?([0-9]+)"?.*/\1/' | head -n 1)
    local scheme=$(grep "traefik.http.services.*.scheme" "$compose_file" | sed -E 's/.*scheme[=:]"?([https]+)"?.*/\1/' | head -n 1)
    local resolver=$(grep "traefik.http.routers.*.certresolver" "$compose_file" | sed -E 's/.*certresolver[=:]"?([^"]+)"?.*/\1/' | head -n 1)
    local middlewares=$(grep "traefik.http.routers.*.middlewares" "$compose_file" | sed -E 's/.*middlewares[=:]"?([^"]+)"?.*/\1/' | head -n 1)
    local serverstransport=$(grep -i "traefik.http.services.*.serverstransport" "$compose_file" | sed -E 's/.*[sS]ervers[tT]ransport[=:]"?([^"]+)"?.*/\1/' | head -n 1)
    
    # Defaults
    [[ -z "$port" ]] && port="80"
    [[ -z "$scheme" ]] && scheme="http"
    [[ -z "$resolver" ]] && resolver="stepca"

    # Target container name logic
    local target_host="${service_name}"
    # Extract container_name from within the service block (between this service
    # definition and the next top-level service or EOF)
    local explicit_name
    explicit_name=$(awk -v svc="  ${service_name}:" '
        $0 ~ "^"svc { found=1; next }
        found && /^  [a-zA-Z0-9_-]+:/ { exit }
        found && /container_name:/ {
            sub(/.*container_name:[[:space:]]*/,"")
            gsub(/"/,"")
            gsub(/[[:space:]]/,"")
            print; exit
        }
    ' "$compose_file")
    
    if [[ -n "$explicit_name" ]]; then
        target_host="$explicit_name"
    elif [[ "$stack_name" == user/* ]]; then
        # Default podman-compose naming if no container_name
        target_host="${stack_name##*/}_${service_name}_1"
    fi
    
    # Core overrides
    # [[ "$service_name" == "quay" ]] && target_host="quay-core"
    # [[ "$service_name" == "wazuh" ]] && target_host="wazuh-dashboard"

    # Detect if an explicit Traefik service is declared (e.g. api@internal)
    local custom_service
    custom_service=$(grep 'traefik.http.routers.*\.service=' "$compose_file" 2>/dev/null | sed -E 's/.*service[=:]"?([^"]+)"?.*/\1/' | head -n 1 || true)

    if [[ -n "$custom_service" ]]; then
        echo ">>> Generating Traefik dynamic config: $rule -> $custom_service"
    else
        echo ">>> Generating Traefik dynamic config: $rule -> $target_host:$port"
    fi

    cat <<EOF > "$output_file"
# Generated by deploy.sh for $stack_name/$service_name
http:
  routers:
    ${stack_name/\//_}_${service_name}:
      rule: '$rule'
$(if [[ -n "$priority" ]]; then echo "      priority: $priority"; fi)
      entryPoints:
        - websecure
      service: ${custom_service:-${stack_name/\//_}_${service_name}}
      tls: {}
EOF
    
    if [[ -n "$resolver" && "$resolver" != "none" ]]; then
        sed -i 's/tls: {}/tls:\n        certResolver: '"$resolver"'/g' "$output_file"
    fi

    if [[ -n "$middlewares" ]]; then
        echo "      middlewares:" >> "$output_file"
        IFS=',' read -ra ADDR <<< "$middlewares"
        for i in "${ADDR[@]}"; do
            echo "        - $i" >> "$output_file"
        done
    fi

    # Only emit a service definition if no custom service override
    if [[ -z "$custom_service" ]]; then
        cat <<EOF >> "$output_file"
  services:
    ${stack_name/\//_}_${service_name}:
      loadBalancer:
        servers:
          - url: "$scheme://$target_host:$port"
EOF

        if [[ -n "$serverstransport" ]]; then
            echo "        serversTransport: $serverstransport" >> "$output_file"
        fi
    fi

    # If stack is remote, sync the generated file
    if [[ "$DEPLOY_MODE" == "remote" ]]; then
        "${SSH_CMD[@]}" "mkdir -p ~/${REMOTE_BASE}/$rel_gen_dir"
        rsync -lpt "$output_file" "$REMOTE_USER@$REMOTE_HOST:~/${REMOTE_BASE}/$rel_gen_dir/$filename"
    fi
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
            if [[ "$DEPLOY_MODE" == "remote" ]]; then
                echo ">>> Delegating remote deployment to Ansible Playbook for $stack_name..."
                ansible-playbook -i "$REMOTE_HOST," -u "$REMOTE_USER" --private-key "$SSH_KEY" "$REPO_ROOT/ansible/deploy-stacks.yml" -e "limit_stacks=$stack_name"
            else
                echo ">>> Delegating local deployment to Ansible Playbook for $stack_name..."
                ansible-playbook -i "localhost," -c local "$REPO_ROOT/ansible/deploy-stacks.yml" -e "limit_stacks=$stack_name"
            fi
            ;;
        redeploy)
            check_security "$REPO_ROOT/$stack_dir" "$stack_name" || return 1
            if [[ "$DEPLOY_MODE" == "remote" ]]; then
                echo ">>> Delegating remote redeployment to Ansible Playbook for $stack_name..."
                ansible-playbook -i "$REMOTE_HOST," -u "$REMOTE_USER" --private-key "$SSH_KEY" "$REPO_ROOT/ansible/deploy-stacks.yml" -e "limit_stacks=$stack_name" -e "force_recreate=true"
            else
                echo ">>> Delegating local redeployment to Ansible Playbook for $stack_name..."
                ansible-playbook -i "localhost," -c local "$REPO_ROOT/ansible/deploy-stacks.yml" -e "limit_stacks=$stack_name" -e "force_recreate=true"
            fi
            ;;
        down)    run_compose "$stack_dir" "down" ;;
        ps)      run_compose "$stack_dir" "ps" ;;
        logs)    run_compose "$stack_dir" "logs" "-f" ;;
        restart) run_compose "$stack_dir" "restart" ;;
        traefik_gen)
            # Used by Ansible to generate dynamic configs locally
            local prev_mode="$DEPLOY_MODE"
            DEPLOY_MODE="local"
            generate_traefik_config "$stack_name"
            DEPLOY_MODE="$prev_mode"
            ;;
        *)
            echo "[ERROR] Unknown command '$COMMAND'."
            echo "Valid: up, down, ps, logs, restart, check, redeploy, traefik_gen"
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

    # Cleanup only the generated configs for the stacks in this batch.
    # Cleaning ALL gen_ files would break routing for stacks not in the batch.
    if [[ "$COMMAND" == "up" || "$COMMAND" == "redeploy" ]]; then
        for stack in "${stacks[@]}"; do
            cleanup_traefik_configs "$stack"
        done
    fi

    # --- QUAY-FIRST BOOTSTRAPPING (Handled by Ansible) ---

    if [[ "$COMMAND" == "up" || "$COMMAND" == "redeploy" ]]; then
        local limit_stacks
        limit_stacks=$(IFS=,; echo "${stacks[*]}")
        local force_flag=""
        [[ "$COMMAND" == "redeploy" ]] && force_flag="-e force_recreate=true"
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            echo ">>> Delegating remote batch deployment to Ansible Playbook..."
            ansible-playbook -i "$REMOTE_HOST," -u "$REMOTE_USER" --private-key "$SSH_KEY" "$REPO_ROOT/ansible/deploy-stacks.yml" -e "limit_stacks=$limit_stacks" $force_flag
        else
            echo ">>> Delegating local batch deployment to Ansible Playbook..."
            ansible-playbook -i "localhost," -c local "$REPO_ROOT/ansible/deploy-stacks.yml" -e "limit_stacks=$limit_stacks" $force_flag
        fi
        if [ $? -ne 0 ]; then
            echo ">>> Batch $COMMAND failed during Ansible execution."
            exit 1
        fi
        echo ">>> Batch $COMMAND completed successfully for all ${#stacks[@]} stack(s) via Ansible."
        return
    fi

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
    cicd)
        # CI/CD pipeline: Gitea (code hosting) + DefectDojo (vuln mgmt)
        # RamaLama (AI log triage) enabled only when a GPU is detected on the target host.
        GPU_TYPE=$(detect_remote_gpu)
        if [[ "$GPU_TYPE" != "none" ]]; then
            echo ">>> GPU detected ($GPU_TYPE) — enabling RamaLama in CI/CD batch."
            export GPU_TYPE
            deploy_batch "defectdojo" "gitea" "ramalama"
        else
            echo ">>> No GPU detected — RamaLama requires a GPU and will be skipped."
            echo "    To enable: add a GPU to the host and re-run './deploy.sh cicd up'."
            deploy_batch "defectdojo" "gitea"
        fi
        ;;
    dev)
        # Developer tools: pkg-sentinel (Supply-Chain Security Proxy)
        # ramalama disabled — see TODO in README.md
        deploy_batch "pkg-sentinel"
        ;;
    *)
        # Always cleanup old generated configs at the start of a run (if up/redeploy)
        if [[ "$COMMAND" == "up" || "$COMMAND" == "redeploy" ]]; then
            cleanup_traefik_configs "$STACK_NAME"
        fi
        deploy_single "$STACK_NAME"
        echo ">>> Done."
        ;;
esac
