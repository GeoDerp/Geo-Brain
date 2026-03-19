# GEO-Brain DevSecOps Architectural Roadmap

This roadmap outlines the prioritized steps to mature the GEO-Brain homelab from its current state into a highly resilient, enterprise-ready DevSecOps platform, strictly maintaining the rootless Podman architecture.

## Phase 1: Immediate Fixes (Bootstrapping & Core Security)

**Objective:** Fully automate the post-deployment configuration, eliminate plaintext secrets, and solidify the Harbor-first deployment model.

1.  **Idempotent Rootless Bootstrapper (Completed)**
    *   `setup-geo-brain.sh` handles Harbor initialization, PKI (Step-CA & Traefik ACME), Identity (Kanidm OIDC), and SOC (DefectDojo) bridging.
    *   Dynamically extracts API keys and provisions them securely using `podman secret create`.

2.  **Secret Management Transition (Podman Secrets)**
    *   **Rationale:** Stop passing highly sensitive dynamic values via `.env` files.
    *   **Implementation:** Transition compose files to use `secrets` explicitly.
    ```yaml
    # Example quadlet/compose transition:
    services:
      my-app:
        image: harbor.example.local/my-app:1.0
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

1.  **Declarative Zero-Trust User Stacks (Dockge + Traefik/Step-CA)**
    *   **Rationale:** Users should easily spin up apps without configuring complex PKI.
    *   **Implementation:** Traefik uses the internal Step-CA ACME challenge. User stacks deployed via Dockge only need standard Traefik labels.
    *   **STIG Compliance:** Enforce `read_only: true`, drop `ALL` capabilities, and mount a temporary `tmpfs` for `/tmp`.
    ```yaml
    # STIG-Compliant User Stack Template
    services:
      user-app:
        image: harbor.example.local/my-app:latest
        read_only: true
        tmpfs:
          - /tmp
        cap_drop:
          - ALL
        networks:
          - user-net
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.app.rule=Host(`app.${DOMAIN}`)"
          - "traefik.http.routers.app.tls.certresolver=stepca"
    ```

2.  **Rootless eBPF Monitoring (Falco to Wazuh)**
    *   **Rationale:** Traditional Falco requires root Docker sockets or kernel module access.
    *   **Implementation:** Utilize the modern eBPF driver (`falco-bpf`). Since Podman rootless isolates namespaces, Falco must run with `security.stig.bypass_privileged=true` just for the specific eBPF capability to monitor syscalls across user namespaces. Route alerts via local Syslog (`logger`) to Vector, forwarding them into Wazuh.

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
