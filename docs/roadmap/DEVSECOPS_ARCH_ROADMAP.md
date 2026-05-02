# STIG-Homelab DevSecOps Architectural Roadmap

This roadmap outlines the prioritized steps to mature the STIG-Homelab homelab from its current state into a highly resilient, enterprise-ready DevSecOps platform, strictly maintaining the rootless Podman architecture.

## Phase 1: Immediate Fixes (Bootstrapping & Core Security)

**Objective:** Fully automate the post-deployment configuration, eliminate plaintext secrets, and solidify the Quay-first deployment model.

1.  **Idempotent Rootless Bootstrapper (Completed)**
    *   `setup-brain.sh` handles Quay initialization, PKI (Step-CA & Traefik ACME), Identity (Kanidm OIDC), and SOC (DefectDojo) bridging.
    *   Dynamically extracts API keys and provisions them securely using `podman secret create`.

2.  **Secret Management Transition (Podman Secrets) (Partial)**
    *   **Rationale:** Stop passing highly sensitive dynamic values via `.env` files.
    *   **Progress:** `setup-brain.sh` now creates Podman secrets for all OIDC client secrets (`*_oidc_secret`) and `dojo_secret_key`. Remaining: transition all compose files to consume secrets via the `secrets:` top-level key instead of environment variables.

3.  **Rootless Permissions & Ports (< 1024) (Completed)**
    *   **Rationale:** Binding Traefik to `443` without root requires explicit sysctl configs.
    *   **Implementation:** `ansible/init-node.yml` sets `net.ipv4.ip_unprivileged_port_start=80` and manages `subuid`/`subgid` mapping for database containers.

4.  **OAuth2 Proxy SSO Gateway (Completed)**
    *   **Rationale:** Centralized OIDC-based forward-auth via Kanidm, eliminating the need for LDAP service accounts.
    *   **Implementation:** Dual-instance deployment (`oauth2-proxy` for `stig_users` + `stig_admins`, `oauth2-proxy-admin` for `stig_admins` only). Traefik ForwardAuth middlewares route all protected services through OAuth2 Proxy → Kanidm OIDC.

5.  **Gitea CI/CD Pipeline (Completed)**
    *   **Rationale:** Self-hosted Git with integrated CI/CD runners for air-gapped DevSecOps.
    *   **Implementation:** Gitea deploys with native Kanidm OIDC authentication (not ForwardAuth — git CLI can't handle 302 redirects). Two pinned runners (`act_runner:0.2.11`): an ephemeral sandbox runner for CI/CD jobs and a routine runner for scheduled Trivy (`0.58.2`) scans of mirrored repos. Gitea, DefectDojo, and RamaLama form an optional CI/CD group on `vulnerability-net`, deployed via `./deploy.sh cicd up`. Excluded from `deploy.sh all` batch by default.

## Phase 2: Observability & Operational Maturity

**Objective:** Implement strict internal networking, secure user stack onboarding, and AI-driven security analysis.

1.  **Declarative Zero-Trust User Stacks & mTLS Sidecars (Completed)**
    *   **Rationale:** Internal services shouldn't implicitly trust each other.
    *   **Implementation:** Backend databases and apps bind only to `127.0.0.1` and share a network namespace with a Caddy proxy sidecar that handles mTLS termination via Step-CA.

2.  **Automated Rootless eBPF Remediation (Completed)**
    *   **Rationale:** We need an active SOC loop to instantly quarantine compromised containers.
    *   **Implementation:** Falco uses the modern eBPF nodriver engine running with `security.stig.bypass_privileged=true`. Alerts are routed Falco → Vector → CrowdSec → Traefik/Caddy bouncers.

3.  **BunkerWeb L7 WAF (Deployed — WIP)**
    *   **Rationale:** Perimeter defense at the HTTP layer before traffic reaches Traefik.
    *   **Implementation:** BunkerWeb (ModSecurity + OWASP CRS) deployed in the boot order. Provides rate limiting, DDoS protection, bot mitigation, and CrowdSec integration. Sits in front of Traefik on `waf-net`.

4.  **Rootless-Aware Observability (Prometheus & Exporters)**
    *   **Rationale:** `podman-exporter` was removed as it required breaking SELinux confinement to access the host podman socket, violating strict DISA STIG compliance.
    *   **Implementation:** Prometheus is in the boot order but excluded from batch deploys (`exclude_stacks`). Review node-level exporters or alternative metrics gathering methods that do not require unconfined host access.

5.  **Declarative SSO for Observability (Grafana, Loki, Prometheus)**
    *   **Rationale:** Centralized visibility shouldn't rely on local accounts.
    *   **Progress:** Grafana currently receives auth via OAuth2 Proxy ForwardAuth headers (automatic SSO). Remaining: evaluate native Kanidm OIDC integration for Grafana, and OIDC/Basic Auth backed by Kanidm LDAP for Loki and Prometheus.

6.  **LLM & AI-Driven SOC Operations (RamaLama) [Deployed — Integration WIP]**
    *   **Rationale:** Local LLMs provide private, air-gapped log analysis and security auditing.
    *   **Implementation:** The `ramalama` stack deploys as part of the CI/CD pipeline group (`./deploy.sh cicd up`) on `secure-backbone` (internal/air-gapped), `wazuh-net`, and `vulnerability-net`. Remaining: configure it to scrape logs from Loki and integrate with Wazuh/DefectDojo for automated triage, and hook into Gitea for AI-assisted code reviews on pull requests.

## Phase 3: Long-Term Architectural Shifts (Advanced Identity & Airgap)

1.  **Kanidm / Step-CA SSH Certificate Authority**
    *   **Rationale:** Eliminate static SSH keys completely.
    *   **Implementation:** Configure Kanidm OIDC to authenticate users against Step-CA. Step-CA issues short-lived SSH certificates for host access.

2.  **Vaultwarden as the SSOT for Infrastructure Secrets**
    *   **Rationale:** Podman secrets are great, but Vaultwarden should hold the encrypted master state.
    *   **Implementation:** Future deployment scripts will authenticate with Vaultwarden CLI (`bw-cli`) using a machine token to pull required variables.
