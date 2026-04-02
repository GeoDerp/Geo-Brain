# GEMINI Context: Geo-Brain (Single Source of Truth)

This repository serves as the Single Source of Truth (SSOT) for a DISA STIG compliant, single-node homelab. It manages infrastructure-as-code via Podman and Docker Compose.

## Core Architecture
- **Host OS:** openSUSE MicroOS or Fedora CoreOS (Transactional/Atomic, Read-Only Root FS).
- **Container Engine:** Podman (Rootless by default).
- **Domain:** `${DOMAIN}` (Default: `example.local`).
- **Interface:** 
  - Primary: Podman remote access (via `podman.socket`).
  - Secondary: `ssh` (Break-glass/Fix-only).

## Mandates & Standards
- **STIG Compliance:** All configurations must align with DISA STIGs for Linux and Container Security.
- **Tool Selection:** All tools added as a stack must be DISA STIG compliant, highly relied upon (industry-backed), and regularly scanned/maintained.
- **Rootless:** All containers MUST run as rootless. Exceptions (e.g., Falco eBPF) must be explicitly labeled with `security.stig.bypass_privileged=true`.
- **Reliability:** Every service must define `deploy.resources.limits` and `healthcheck`.
- **Zero-Trust mTLS Architecture:** All backend services and databases MUST utilize the mTLS Sidecar Pattern (e.g., Caddy). Applications bind strictly to `127.0.0.1` and share a network namespace with a sidecar proxy that handles mTLS termination via Step-CA. 
- **Network Micro-Segmentation:** Applications reside on dedicated Podman networks. Internal backend networks MUST be set to `internal: true` to air-gap them and drop the default NAT gateway. No inter-stack communication unless explicitly defined via an mTLS sidecar.
- **Air-gap Preparedness:** All images are pinned to specific versions/digests. No `:latest` tags.
- **Data Separation:** Persistent data lives under `${DATA_DIR}` (default `/var/Geo-Brain`) on a large partition. Config files stay relative (`./config`) for rsync portability. New stacks mount data as `${DATA_DIR}/<stack-name>/...`.
- **Single Source of Truth:** All infrastructure state is defined in this repository. Manual changes on the host are forbidden.
- **HTTPS Only:** All HTTP endpoints MUST be encrypted with TLS. Plain HTTP is only allowed for local bootstrap redirects to HTTPS.

## Application Stack 

### Management & Dashboard
- **Homepage:** Centralized dashboard with service discovery via labels.
- **Dockge:** Primary stack manager for Compose-based deployments.
- **RamaLama:** AI-driven log analysis using local LLMs (e.g., Phi-3) for air-gapped SOC operations.

### Security Operations Center (SOC)
- **Wazuh (SIEM/XDR):** Centralized security monitoring and log indexing.
- **Falco:** Runtime security monitoring using the nodriver (userspace) engine. Detects anomalies, including inter-container network bypasses.
- **CrowdSec:** Intrusion prevention and multi-layer blocking. Configured strictly as Air-Gapped (Zero Telemetry/Upload). Powers the automated remediation loop by parsing Falco alerts via Vector and updating Caddy sidecar bouncers.
- **DefectDojo:** Vulnerability management and orchestration of scan results.

### Observability & Logging (The "LGV" Stack)
- **Grafana:** Centralized visualization for metrics and logs.
- **Prometheus:** Time-series metrics collection and alerting.
- **Loki:** Log aggregation and long-term storage.
- **Vector:** High-performance log pipeline for host and container log collection.

### Identity & Security Infrastructure
- **Kanidm (IDM):** Primary Identity Management server (LDAP/OIDC).
- **Authelia (Auth Portal):** Single Sign-On portal and 2FA provider.
- **Step-CA (PKI):** Internal Certificate Authority for automated TLS (`*.example.local`).
- **Quay (Registry):** Local OCI registry and pull-through cache with integrated Clair scanning.
- **MinIO (Storage):** S3-compatible object storage for Loki chunks and Velero/Restic backups.

### Optional Stacks (WIP)
- **Pangolin (Tunnel Proxy):** Identity-aware reverse proxy and WireGuard VPN for zero-trust remote access. Replaces Traefik + Authelia when used.
- **BunkerWeb (WAF):** L7 Web Application Firewall with ModSecurity + OWASP CRS, rate limiting, DDoS protection, and CrowdSec integration. Sits in front of Traefik.

## Tooling & Automation
- **`init-node.sh`:** Thin wrapper that handles SSH agent setup, argument parsing, and pre-flight checks, then delegates to the Ansible playbook. Accepts `--host`, `--user`, `--key`, `--port`, `--yes` flags; omitted options are prompted interactively.
- **`ansible/init-node.yml`:** Ansible playbook that provisions the remote homelab node (Podman, `podman.socket`, `auditd`, SELinux, firewalld, subuids, linger, sysctl), then registers a local `podman system connection` for remote access. Confirms major changes (package installs, firewall rules, SELinux, podman-remote registration) unless `--yes` / `-e auto_yes=true` is passed.
- **`deploy.sh`:** STIG-compliant deployment wrapper. Validates image pinning, resource limits, and network isolation locally, then syncs and deploys stacks to the remote node via SSH. Falls back to local deployment if no remote is configured.
- **`setup-brain.sh`:** Idempotent rootless Podman post-deployment bootstrapper. It configures Quay as the primary registry, injects the Step-CA root certificate into Traefik, handles automated generation and storage of OIDC secrets, and securely bridges initial application credentials (e.g., DefectDojo).
- **`scripts/sast/sast-scan.sh`:** Automated security scanning using Trivy, Checkov, Gitleaks, and Semgrep.
- **`scripts/secrets/gen-selfsigned-certs.sh`:** Generates required certificate/key bundles with normalized filenames for required stacks (Traefik, Kanidm). Also supports importing existing certificates and converting them to the required filenames and bundle formats.

## Health Monitoring
- Monitor `transactional-update` (MicroOS) or `rpm-ostree` (CoreOS) status.
- Monitor `podman.socket` health.
- Monitor Wazuh/Falco alerts for compliance drift.

## Design Philosophy
- **Declarative:** All deployments and configurations must be strictly declarative. If a tool requires manual GUI setup, find a way to declare it via config files, environment variables, or automated CLI bootstrapping.
- **Idempotency:** Scripts and automation must be safe to run multiple times without causing failures or unintended side-effects. Always check state before applying changes.
- **Simplicity & Maintainability:** The architecture must remain simple and easy to understand. Avoid convoluted logic. New stacks should easily integrate by following the provided templates.
