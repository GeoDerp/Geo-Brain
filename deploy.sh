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
DATA_DIR="${DATA_DIR:-/var/Geo-Brain}"
DATA_DIR="${DATA_DIR/#\~/$HOME}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

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
    REMOTE_BASE="${REMOTE_PROJECT_DIR:-Geo-Brain}"
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
    echo "  all   - Deploy all stacks (base + user)"
    echo "  base  - Deploy all base infrastructure stacks"
    echo "  user  - Deploy all user application stacks"
    exit 1
fi

# --- Stack Discovery ---

get_base_stacks() {
    local ordered_stacks=(
        "step-ca"
        "traefik"
        "bunkerweb"
        "pangolin"
        "kanidm"
        "authelia"
        "minio"
        "loki"
        "vector"
        "prometheus"
        "wazuh"
        "falco"
        "crowdsec"
        "quay"
        "defectdojo"
        "grafana"
        "dockge"
        "homepage"
    )

    local exclude_stacks=("ramalama" "prometheus")
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

    # Sync certs if they exist (needed by some stacks like Quay OIDC)
    if [[ -d "$REPO_ROOT/certs" ]]; then
        "${SSH_CMD[@]}" "mkdir -p ~/${REMOTE_BASE}/certs"
        rsync -rlpt -e "$rsync_ssh" "$REPO_ROOT/certs/" "${REMOTE_USER}@${REMOTE_HOST}:~/${REMOTE_BASE}/certs/"
    fi

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
        local data_dir_val="${DATA_DIR:-/var/Geo-Brain}"
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
        "${SSH_CMD[@]}" "for d in $unique; do mkdir -p \"\$d\" 2>/dev/null || true; done"
    fi
}

# --- Render Config Templates ---
# Expands ${VARIABLE} references in config files on the remote node.
# Required because some apps (Kanidm, Authelia, Traefik dynamic config, Loki)
# read config files directly and cannot expand environment variables natively.

render_config_templates() {
    local stack_dir="$1"

    if [[ "$DEPLOY_MODE" == "remote" ]]; then
        "${SSH_CMD[@]}" bash -s -- "${REMOTE_BASE}" "${stack_dir}" << 'RENDER_SCRIPT'
RBASE="$1"
SDIR="$2"
ENVFILE="$HOME/${RBASE}/.env"
CONFDIR="$HOME/${RBASE}/${SDIR}/config"

cd "$CONFDIR" 2>/dev/null || exit 0
set -a; [ -f "$ENVFILE" ] && source "$ENVFILE"; set +a
command -v envsubst &>/dev/null || exit 0

# Whitelist: only expand variables defined in .env (prevents clobbering app-specific patterns)
VARLIST='${DOMAIN} ${DATA_DIR} ${LDAP_BASE_DN} ${AUTHELIA_LDAP_PASSWORD} ${AUTHELIA_JWT_SECRET} ${AUTHELIA_ENCRYPTION_KEY} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} ${CROWDSEC_BOUNCER_API_KEY} ${QUAY_DB_USER} ${QUAY_DB_PASSWORD} ${QUAY_DB_NAME} ${CLAIR_DB_USER} ${CLAIR_DB_PASSWORD} ${CLAIR_DB_NAME} ${DEFECTDOJO_DB_USER} ${DEFECTDOJO_DB_PASSWORD} ${QUAY_OIDC_SECRET} ${MINIO_OIDC_SECRET} ${WAZUH_OIDC_SECRET} ${DOJO_OIDC_SECRET} ${DOJO_SECRET_KEY} ${N8N_OIDC_SECRET}'
find . -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.toml' -o -name '*.conf' \) 2>/dev/null | while IFS= read -r f; do
    if grep -qE '\$\{[A-Z_]+\}' "$f" 2>/dev/null; then
        envsubst "$VARLIST" < "$f" > "$f.rendered" && mv "$f.rendered" "$f"
    fi
done
RENDER_SCRIPT
    else
        # Local: expand in a temp copy to avoid modifying repo templates
        local config_dir="$REPO_ROOT/$stack_dir/config"
        [[ -d "$config_dir" ]] || return 0
        command -v envsubst &>/dev/null || return 0
        local varlist='${DOMAIN} ${DATA_DIR} ${LDAP_BASE_DN} ${AUTHELIA_LDAP_PASSWORD} ${AUTHELIA_JWT_SECRET} ${AUTHELIA_ENCRYPTION_KEY} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} ${CROWDSEC_BOUNCER_API_KEY} ${QUAY_DB_USER} ${QUAY_DB_PASSWORD} ${QUAY_DB_NAME} ${CLAIR_DB_USER} ${CLAIR_DB_PASSWORD} ${CLAIR_DB_NAME} ${DEFECTDOJO_DB_USER} ${DEFECTDOJO_DB_PASSWORD} ${QUAY_OIDC_SECRET} ${MINIO_OIDC_SECRET} ${WAZUH_OIDC_SECRET} ${DOJO_OIDC_SECRET} ${DOJO_SECRET_KEY} ${N8N_OIDC_SECRET}'
        find "$config_dir" -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.toml' -o -name '*.conf' \) 2>/dev/null | while IFS= read -r f; do
            if grep -qE '\$\{[A-Z_]+\}' "$f" 2>/dev/null; then
                envsubst "$varlist" < "$f" > "$f.rendered" && mv "$f.rendered" "$f"
            fi
        done
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

            echo "  [1/4] Creating remote volume directories..."
            ensure_remote_dirs "$compose_file" "$stack_dir"

            echo "  [2/4] Syncing config to remote (rsync)..."
            rsync_to_remote "$stack_dir"

            echo "  [3/4] Rendering config templates..."
            render_config_templates "$stack_dir"

            echo "  [4/4] Running podman compose $cmd on remote..."
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

    # Extract the first service name that has Traefik labels
    local service_name=$(grep -B 20 "traefik.enable=true" "$compose_file" | grep -E "^  [a-zA-Z0-9_-]+:" | tail -n 1 | sed 's/://' | xargs)
    [[ -z "$service_name" ]] && service_name="${stack_name##*/}"

    local filename="gen_${stack_name/\//_}_${service_name}.yml"
    local output_file="$gen_dir/$filename"

    mkdir -p "$gen_dir"

    # Use the service name as the subdomain if not explicitly overridden by labels
    local rule="Host(\`${service_name}.${DOMAIN}\`)"
    if grep -q "traefik.http.routers.*.rule" "$compose_file"; then
        local raw_rule=$(grep "traefik.http.routers.*.rule" "$compose_file" | sed -E 's/.*Host\(`([^`]+)`\).*/\1/' | head -n 1)
        rule="Host(\`$(echo "$raw_rule" | sed -E "s/\{\{[^}]*DOMAIN[^}]*\}\}/${DOMAIN}/g" | sed -E "s/\\\$[{(]*DOMAIN[)}]* /${DOMAIN}/g" | sed "s/\${DOMAIN}/${DOMAIN}/g")\`)"
    fi
    
    local port=$(grep "traefik.http.services.*.port" "$compose_file" | sed -E 's/.*port[=:]"?([0-9]+)"?.*/\1/' | head -n 1)
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
    # Check if container_name is explicitly set for this service
    local explicit_name=$(grep -A 5 "^  $service_name:" "$compose_file" | grep "container_name:" | sed -E 's/.*container_name:[[:space:]]*"?([^"]+)"?.*/\1/' | xargs)
    
    if [[ -n "$explicit_name" ]]; then
        target_host="$explicit_name"
    elif [[ "$stack_name" == user/* ]]; then
        # Default podman-compose naming if no container_name
        target_host="${stack_name##*/}_${service_name}_1"
    fi
    
    # Core overrides
    # [[ "$service_name" == "quay" ]] && target_host="quay-core"
    # [[ "$service_name" == "wazuh" ]] && target_host="wazuh-dashboard"

    echo ">>> Generating Traefik dynamic config: $rule -> $target_host:$port"

    cat <<EOF > "$output_file"
# Generated by deploy.sh for $stack_name/$service_name
http:
  routers:
    ${stack_name/\//_}_${service_name}:
      rule: "$rule"
      entryPoints:
        - websecure
      service: ${stack_name/\//_}_${service_name}
      tls:
        certResolver: $resolver
EOF

    if [[ -n "$middlewares" ]]; then
        echo "      middlewares:" >> "$output_file"
        IFS=',' read -ra ADDR <<< "$middlewares"
        for i in "${ADDR[@]}"; do
            echo "        - $i" >> "$output_file"
        done
    fi

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
            generate_traefik_config "$stack_name"
            run_compose "$stack_dir" "up" "-d"
            ;;
        redeploy)
            check_security "$REPO_ROOT/$stack_dir" "$stack_name" || return 1
            generate_traefik_config "$stack_name"
            echo ">>> Forcing recreation of containers for $stack_name..."
            run_compose "$stack_dir" "down"
            run_compose "$stack_dir" "up" "-d" "--force-recreate"
            ;;
        down)    run_compose "$stack_dir" "down" ;;
        ps)      run_compose "$stack_dir" "ps" ;;
        logs)    run_compose "$stack_dir" "logs" "-f" ;;
        restart) run_compose "$stack_dir" "restart" ;;
        *)
            echo "[ERROR] Unknown command '$COMMAND'."
            echo "Valid: up, down, ps, logs, restart, check, redeploy"
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

    # Always cleanup old generated configs at the start of a run (if up/redeploy)
    if [[ "$COMMAND" == "up" || "$COMMAND" == "redeploy" ]]; then
        cleanup_traefik_configs
    fi

    # --- QUAY-FIRST BOOTSTRAPPING ---
    if [[ " ${stacks[*]} " =~ " quay " ]] && [[ "$COMMAND" == "up" || "$COMMAND" == "redeploy" ]]; then
        echo ">>> [BOOTSTRAP] Deploying Step-CA, Traefik, and Quay as the primary SSOT registry..."
        deploy_single "step-ca"
        deploy_single "traefik"
        deploy_single "quay"

        # Wait for Quay API to become healthy (max 3 minutes)
        echo ">>> [BOOTSTRAP] Waiting for Quay API to report healthy..."
        QUAY_URL="http://localhost:8080/health/instance"
        for i in {1..36}; do
            if [[ "$DEPLOY_MODE" == "remote" ]]; then
                if "${SSH_CMD[@]}" "curl -sk \"$QUAY_URL\" | grep -qi \"true\"" 2>/dev/null; then
                    echo ">>> [BOOTSTRAP] Quay is UP and HEALTHY."
                    break
                fi
            else
                if curl -sk "$QUAY_URL" | grep -qi "true" 2>/dev/null; then
                    echo ">>> [BOOTSTRAP] Quay is UP and HEALTHY."
                    break
                fi
            fi
            sleep 5
            if [ "$i" -eq 36 ]; then
                echo "[ERROR] Quay failed to become healthy in time."
                exit 1
            fi
        done

        # Authenticate to the local instance (using podman over ssh if REMOTE)
        echo ">>> [BOOTSTRAP] Authenticating local Podman to Quay..."
        local login_success=0
        if [[ "$DEPLOY_MODE" == "remote" ]]; then
            if "${SSH_CMD[@]}" "podman login \"quay.${DOMAIN:-example.local}\" -u quayuser -p \"${QUAY_DB_PASSWORD}\" --tls-verify=false" >/dev/null 2>&1; then
                login_success=1
            else
                echo ">>> [WARNING] Quay authentication failed. Skipping mirror configuration."
            fi
            
            if [ "$login_success" -eq 1 ]; then
                "${SSH_CMD[@]}" "mkdir -p ~/.config/containers && cat <<EOF > ~/.config/containers/registries.conf
unqualified-search-registries = [\"docker.io\"]

[[registry]]
prefix = \"docker.io\"
location = \"quay.${DOMAIN:-example.local}\"
insecure = true
EOF
"
                echo ">>> [BOOTSTRAP] registries.conf updated. Mirror active."
            fi
        else
            if podman login "quay.${DOMAIN:-example.local}" -u quayuser -p "${QUAY_DB_PASSWORD}" --tls-verify=false >/dev/null 2>&1; then
                login_success=1
            else
                echo ">>> [WARNING] Quay authentication failed. Skipping mirror configuration."
            fi

            if [ "$login_success" -eq 1 ]; then
                mkdir -p ~/.config/containers
                cat <<EOF > ~/.config/containers/registries.conf
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "quay.${DOMAIN:-example.local}"
insecure = true
EOF
                echo ">>> [BOOTSTRAP] registries.conf updated. Mirror active."
            fi
        fi
    fi
    # --- END QUAY-FIRST BOOTSTRAPPING ---


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
        # Always cleanup old generated configs at the start of a run (if up/redeploy)
        if [[ "$COMMAND" == "up" || "$COMMAND" == "redeploy" ]]; then
            cleanup_traefik_configs "$STACK_NAME"
        fi
        deploy_single "$STACK_NAME"
        echo ">>> Done."
        ;;
esac
