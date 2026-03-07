# GEMINI Context: brain-ssof (Single Source of Truth)

This repository serves as the Single Source of Truth (SSOT) for a DISA STIG compliant, single-node homelab. It manages infrastructure-as-code via Podman and Docker Compose.

## Core Architecture
- **Host OS:** openSUSE MicroOS (Transactional, Read-Only Root FS).
- **Container Engine:** Podman (Rootless by default).
- **Domain:** `example.local`.
- **Interface:** 
  - Primary: Podman remote access.
  - Secondary: `ssh -i .ssh/id_rsa user@example.local` (Break-glass/Fix-only).

## Mandates & Standards
- **STIG Compliance:** All configurations must align with DISA STIGs for Linux and Container Security.
- **Rootless:** All containers MUST run as rootless unless a specific hardware requirement or low-level network bind (e.g., port 53/443) requires root, and even then, `ambient_capabilities` or `slirp4netns` should be explored first.
- **Network Isolation:** Applications should reside on dedicated Podman networks with no inter-stack communication unless explicitly defined.
- **Air-gap Preparedness:** Ensure all images are pinned to specific digests and localized. Avoid external "latest" tags.

## Application Stack

### Management & Observability
- **Homepage:** [benphelps/homepage](https://github.com/benphelps/homepage). Use labels for service discovery.
- **Dockge:** [louislam/dockge](https://github.com/louislam/dockge). Primary stack manager. Stacks must be synced from this repo.
- **RamaLama:** AI-driven log analysis. Utilizes light LLMs (e.g., Phi-3) to evaluate and prioritize SOC alerts for human operators. **Air-gapped deployment** with no egress and local-only model storage.

### Security Operations Center (SOC)
- **Wazuh (SIEM/XDR):** 
  - Ingests `journald` logs via **Fluent-bit**.
  - Monitors `auditd` for host-level syscalls.
  - Dedicated dashboard for SELinux AVC denials and compliance drifts.
- **Falco:** Runtime security monitoring. Forwards logs to Wazuh.
- **OpenSCAP:** Periodic STIG compliance scanning of the host and containers.
- **DefectDojo:** Centralized vulnerability management for orchestrating scan results.

### Vulnerability Management & Compliance (Offline Suite)
A suite of tools will periodically scan all running Podman containers and their underlying images. All reports are automatically ingested into **DefectDojo**.
- **Trivy / Grype:** Scans images/filesystems for known vulnerabilities (CVEs).
- **Dockle:** Container image linter/security auditor for best practices.
- **Checkov / Terrascan:** Scans Docker Compose files for infrastructure-as-code (IaC) misconfigurations.
- **Gitleaks:** Scans all repositories for potential secret exposures.
- **Compliance Integration:** OpenSCAP scan results are transformed into formats compatible with DefectDojo for unified compliance reporting.

### Strategic Infrastructure Additions (Security & Air-gap)
- **Identity (IAM):** **Kanidm** or **Authelia**. Required for centralized, MFA-protected access to all web interfaces.
- **Secret Management:** **Vaultwarden**. Localized, encrypted storage for application credentials. No plain-text secrets in this repo.
- **Local Registry:** **Harbor**. Acts as a pull-through cache/mirror to support air-gapped operations and perform vulnerability scanning (Trivy).
- **Certificate Authority:** **Step-CA**. Issues internal TLS certificates for `*.example.local` to ensure encrypted traffic without external dependency.
- **Intrusion Prevention:** **CrowdSec**. Podman-compatible bouncer to mitigate brute-force attempts at the edge.

## Tooling & Automation
- **`deploy.sh`:** (To be created) Wrapper for `podman-compose` to validate STIG-compliant labels and security optics before deployment.
- **`init-node.sh`:** (To be created) Bootstrap script to configure MicroOS for remote Podman access, install `auditd`, and set up user namespaces.

## Health Monitoring
- Monitor `transactional-update` status on MicroOS.
- Monitor `podman.socket` health.
- Monitor Wazuh agent connectivity and Falco rule triggers.
