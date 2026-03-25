# GEO-Brain DevSecOps Architectural Roadmap

This roadmap outlines the prioritized steps to mature the GEO-Brain homelab from its current state into a highly resilient, enterprise-ready DevSecOps platform, strictly maintaining the rootless Podman architecture.

## Phase 1: Immediate Fixes (Bootstrapping & Core Security)

**Objective:** Fully automate the post-deployment configuration, eliminate plaintext secrets, and solidify the Quay-first deployment model.

1.  **Idempotent Rootless Bootstrapper (Completed)**
    *   `setup-geo-brain.sh` handles Quay initialization, PKI (Step-CA & Traefik ACME), Identity (Kanidm OIDC), and SOC (DefectDojo) bridging.
    *   Dynamically extracts API keys and provisions them securely using `podman secret create`.

2.  **Secret Management Transition (Podman Secrets)**
    *   **Rationale:** Stop passing highly sensitive dynamic values via `.env` files.
    *   **Implementation:** Transition compose files to use `secrets` explicitly.
    ```yaml
    # Example quadlet/compose transition:
    services:
      my-app:
        image: quay.example.local/my-app:1.0
        secrets:
          - source: db_password
            target: /run/secrets/db_password
    secrets:
      db_password:
        external: true
    ```

3.  **Rootless Permissions & Ports (< 1024)**
    *   **Rationale:** Binding Traefik to `443` without root requires explicit sysctl configs.
    *   **Implementation:** Ensure Ansible/init scripts set `net.ipv4.ip_unprivileged_port_start=80` and explicitly manage `subuid`/`subgid` mapping for database containers (e.g., Postgres mapping user 999 to the correct host namespace).

## Phase 2: Medium-Term Upgrades (Zero-Trust & Observability)

**Objective:** Implement strict internal networking, secure user stack onboarding, and rootless-aware observability.

1.  **Declarative Zero-Trust User Stacks & mTLS Sidecars (Completed)**
    *   **Rationale:** Internal services shouldn't implicitly trust each other. Plaintext internal networks are an attack vector.
    *   **Implementation:** Backend databases and apps bind only to `127.0.0.1` and share a network namespace with a Caddy proxy sidecar. The sidecar handles mTLS via Step-CA. Internal application networks are set to `internal: true` to physically sever internet access. User-facing apps use Traefik labels with Step-CA integration.

2.  **Automated Rootless eBPF Remediation (Completed)**
    *   **Rationale:** We need an active SOC loop to instantly quarantine compromised containers, not just log them.
    *   **Implementation:** Utilize the modern eBPF driver (`falco-bpf`) running with `security.stig.bypass_privileged=true`. Falco monitors syscalls for inter-container network bypasses. Vector ingests these alerts, routing them simultaneously to Wazuh (SIEM) and to an air-gapped, zero-telemetry CrowdSec container. CrowdSec instantly pushes IP bans to Caddy bouncers, cutting off unauthorized internal container traffic.

3.  **Rootless-Aware Observability (Podman Exporter)**
    *   **Rationale:** Standard cAdvisor doesn't understand rootless Podman cgroups correctly.
    *   **Implementation:** Deploy the official `prometheus-podman-exporter` directly within the user namespace to scrape accurate memory/CPU limits without needing `/var/run/docker.sock`.

## Phase 3: Long-Term Architectural Shifts (Advanced Identity & Airgap)

1.  **Kanidm / Step-CA SSH Certificate Authority**
    *   **Rationale:** Eliminate static SSH keys (e.g., `~/.ssh/authorized_keys`) completely.
    *   **Implementation:** Configure Kanidm OIDC to authenticate users against Step-CA. Step-CA issues short-lived SSH certificates for break-glass operations to the host, ensuring perfectly audited and expiring access.

2.  **Vaultwarden as the SSOT for Infrastructure Secrets**
    *   **Rationale:** Podman secrets are great, but Vaultwarden should hold the encrypted master state.
    *   **Implementation:** Future deployment scripts will authenticate with Vaultwarden CLI (`bw-cli`) using a machine token, pull required variables, and inject them into `podman secret create` during runtime deployment, leaving zero trace on the disk.
