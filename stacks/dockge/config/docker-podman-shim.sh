#!/bin/bash
# docker-podman-shim.sh — Makes Dockge status detection work with Podman.
#
# Podman-compose containers carry the same com.docker.compose.* labels that
# Docker Compose v2 expects, but "docker compose ls" still returns [] because
# Docker Compose v2 does its own internal project tracking that is incompatible
# with podman-compose.
#
# This shim intercepts "docker compose ls" and "docker compose ps" and queries
# the Podman-compat API directly through the mounted socket, producing the
# JSON that Dockge expects. All other commands pass through to /usr/bin/docker.

set -euo pipefail
REAL_DOCKER=/usr/bin/docker
SOCK=/var/run/docker.sock
LOG=/tmp/docker-shim.log

# ---- Debug logging (rotate at 100KB) -----------------------------------
_log() { echo "[$(date -Iseconds)] $*" >> "$LOG" 2>/dev/null || true; }
if [[ -f "$LOG" ]] && [[ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 102400 ]]; then
    mv "$LOG" "${LOG}.1" 2>/dev/null || true
fi
_log "CALLED: $0 $*"

# ---- Detect subcommand -------------------------------------------------
# Dockge always calls: docker compose <sub> [flags…]
if [[ "${1:-}" == "compose" ]]; then
    SUB="${2:-}"
    shift 2  # remaining args are flags like --all --format json
    _log "COMPOSE SUB=$SUB ARGS=$*"

    case "$SUB" in
        ls)
            exec /usr/local/bin/node -e '
const http = require("http");
const args = process.argv.slice(2);
const wantJSON = args.includes("json");

const req = http.request(
    { socketPath: "/var/run/docker.sock", path: "/v1.41/containers/json?all=true", method: "GET" },
    (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
            try {
                const containers = JSON.parse(data);
                const projects = {};
                for (const c of containers) {
                    const project = (c.Labels || {})["com.docker.compose.project"];
                    if (!project) continue;
                    if (!projects[project]) {
                        const cfg =
                            (c.Labels || {})["com.docker.compose.project.config_files"] || "";
                        projects[project] = { Name: project, ConfigFiles: cfg, running: 0, exited: 0, created: 0 };
                    }
                    const st = (c.State || "").toLowerCase();
                    if (st === "running") projects[project].running++;
                    else if (st === "exited") projects[project].exited++;
                    else projects[project].created++;
                }
                const result = Object.values(projects).map((p) => {
                    const parts = [];
                    if (p.running > 0) parts.push("running(" + p.running + ")");
                    if (p.exited > 0) parts.push("exited(" + p.exited + ")");
                    if (p.created > 0) parts.push("created(" + p.created + ")");
                    return { Name: p.Name, Status: parts.join(", ") || "unknown", ConfigFiles: p.ConfigFiles };
                });
                if (wantJSON) {
                    process.stdout.write(JSON.stringify(result) + "\n");
                } else {
                    console.log("NAME\tSTATUS\tCONFIG FILES");
                    for (const r of result) console.log(r.Name + "\t" + r.Status + "\t" + r.ConfigFiles);
                }
            } catch (e) {
                process.stdout.write("[]\n");
            }
        });
    }
);
req.on("error", () => { process.stdout.write("[]\n"); });
req.end();
' -- "$@"
            ;;

        ps)
            # Dockge sets cwd to the stack path; project = basename of cwd
            PROJECT="$(basename "$PWD")"
            exec /usr/local/bin/node -e '
const http = require("http");
const project = process.argv[1];
const filter = encodeURIComponent(JSON.stringify({ label: ["com.docker.compose.project=" + project] }));

const req = http.request(
    { socketPath: "/var/run/docker.sock", path: "/v1.41/containers/json?all=true&filters=" + filter, method: "GET" },
    (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
            try {
                const containers = JSON.parse(data);
                // Dockge parses one JSON object per line
                for (const c of containers) {
                    const name = ((c.Names || [])[0] || "").replace(/^\//, "");
                    const service = (c.Labels || {})["com.docker.compose.service"] || name;
                    const state = (c.State || "unknown").toLowerCase();
                    const statusStr = c.Status || "";
                    const healthMatch = statusStr.match(/\((healthy|unhealthy|starting)\)/i);
                    const health = healthMatch ? healthMatch[1] : "";
                    const obj = {
                        ID: (c.Id || "").substring(0, 12),
                        Name: name,
                        Service: service,
                        State: state,
                        Health: health,
                        Status: statusStr
                    };
                    process.stdout.write(JSON.stringify(obj) + "\n");
                }
            } catch (e) {
                // empty output on error
            }
        });
    }
);
req.on("error", () => {});
req.end();
' -- "$PROJECT" "$@"
            ;;

        *)
            # All management commands (up, down, stop, restart, pull, logs, exec, …)
            _log "PASSTHROUGH: compose $SUB $*"
            exec "$REAL_DOCKER" compose "$SUB" "$@"
            ;;
    esac
else
    # Non-compose docker commands (ps, inspect, version, …)
    _log "PASSTHROUGH: $*"
    exec "$REAL_DOCKER" "$@"
fi
