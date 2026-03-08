# GEMINI Context: brain-ssof (Single Source of Truth)

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
- **Network Isolation:** Applications reside on dedicated Podman networks. No inter-stack communication unless explicitly defined.
- **Air-gap Preparedness:** All images are pinned to specific versions/digests. No `:latest` tags.
- **Single Source of Truth:** All infrastructure state is defined in this repository. Manual changes on the host are forbidden.

## Application Stack 

### Management & Dashboard
- **Homepage:** Centralized dashboard with service discovery via labels.
- **Dockge:** Primary stack manager for Compose-based deployments.
- **RamaLama:** AI-driven log analysis using local LLMs (e.g., Phi-3) for air-gapped SOC operations.

### Security Operations Center (SOC)
- **Wazuh (SIEM/XDR):** Centralized security monitoring and log indexing.
- **Falco:** Runtime security monitoring using modern eBPF.
- **CrowdSec:** Intrusion prevention and multi-layer blocking.
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
- **Harbor (Registry):** Local OCI registry and pull-through cache with integrated Trivy scanning.
- **MinIO (Storage):** S3-compatible object storage for Loki chunks and Velero/Restic backups.

## Tooling & Automation
- **`deploy.sh`:** STIG-compliant wrapper that validates image pinning, resource limits, and network isolation before execution.
- **`init-node.sh`:** Multi-OS bootstrap script for MicroOS/CoreOS; configures `auditd`, `subuids`, and `vm.max_map_count`.
- **`scripts/sast/sast-scan.sh`:** Automated security scanning using Trivy, Checkov, Gitleaks, and Semgrep.

## Health Monitoring
- Monitor `transactional-update` (MicroOS) or `rpm-ostree` (CoreOS) status.
- Monitor `podman.socket` health.
- Monitor Wazuh/Falco alerts for compliance drift.
