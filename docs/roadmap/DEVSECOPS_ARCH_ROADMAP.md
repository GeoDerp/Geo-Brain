# GEO-Brain DevSecOps Architectural Roadmap

This roadmap outlines the prioritized steps to mature the GEO-Brain homelab from its current state into a highly resilient, enterprise-ready DevSecOps platform, strictly maintaining the rootless Podman architecture.

## Phase 1: Immediate Fixes (Bootstrapping & Core Security)

**Objective:** Fully automate the post-deployment configuration, eliminate plaintext secrets, and solidify the Quay-first deployment model.

1.  **Idempotent Rootless Bootstrapper (Completed)**
    *   `setup-brain.sh` handles Quay initialization, PKI (Step-CA & Traefik ACME), Identity (Kanidm OIDC), and SOC (DefectDojo) bridging.
    *   Dynamically extracts API keys and provisions them securely using `podman secret create`.

2.  **Secret Management Transition (Podman Secrets)**
    *   **Rationale:** Stop passing highly sensitive dynamic values via `.env` files.
    *   **Implementation:** Transition compose files to use `secrets` explicitly.

3.  **Rootless Permissions & Ports (< 1024)**
    *   **Rationale:** Binding Traefik to `443` without root requires explicit sysctl configs.
    *   **Implementation:** Ensure Ansible/init scripts set `net.ipv4.ip_unprivileged_port_start=80` and explicitly manage `subuid`/`subgid` mapping for database containers.

## Phase 2: Observability & Operational Maturity

**Objective:** Implement strict internal networking, secure user stack onboarding, and AI-driven security analysis.

1.  **Declarative Zero-Trust User Stacks & mTLS Sidecars (Completed)**
    *   **Rationale:** Internal services shouldn't implicitly trust each other. 
    *   **Implementation:** Backend databases and apps bind only to `127.0.0.1` and share a network namespace with a Caddy proxy sidecar. 

2.  **Automated Rootless eBPF Remediation (Completed)**
    *   **Rationale:** We need an active SOC loop to instantly quarantine compromised containers.
    *   **Implementation:** Utilize the modern eBPF driver (`falco-bpf`) running with `security.stig.bypass_privileged=true`. 

3.  **Rootless-Aware Observability (Prometheus & Exporters)**
    *   **Rationale:** `podman-exporter` was removed as it required breaking SELinux confinement to access the host podman socket, violating strict DISA STIG compliance.
    *   **Implementation:** Prometheus stack is currently disabled in `deploy.sh`. Review node-level exporters or alternative metrics gathering methods that do not require unconfined host access.

4.  **Declarative SSO for Observability (Grafana, Loki, Prometheus)**
    *   **Rationale:** Centralized visibility shouldn't rely on local accounts.
    *   **Implementation:** Update Grafana to utilize OIDC via Kanidm directly. Configure Loki and Prometheus to support OIDC/Basic Auth backed by Kanidm LDAP.

5.  **LLM & AI-Driven SOC Operations (RamaLama) [TODO]**
    *   **Rationale:** local LLMs provide private, air-gapped log analysis and security auditing.
    *   **Implementation:** Re-enable the `ramalama` stack. Configure it to scrape logs from Loki and provide automated analysis using local models (e.g., Phi-3 or Llama-3). Setup declarative OIDC for the LLM UI.

## Phase 3: Long-Term Architectural Shifts (Advanced Identity & Airgap)

1.  **Kanidm / Step-CA SSH Certificate Authority**
    *   **Rationale:** Eliminate static SSH keys completely.
    *   **Implementation:** Configure Kanidm OIDC to authenticate users against Step-CA. Step-CA issues short-lived SSH certificates for host access.

2.  **Vaultwarden as the SSOT for Infrastructure Secrets**
    *   **Rationale:** Podman secrets are great, but Vaultwarden should hold the encrypted master state.
    *   **Implementation:** Future deployment scripts will authenticate with Vaultwarden CLI (`bw-cli`) using a machine token to pull required variables.
