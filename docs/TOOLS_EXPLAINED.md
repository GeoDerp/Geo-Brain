# GEO-Brain Tools: A Deep Dive

This document provides an educational overview of all tools and technologies used in the GEO-Brain SSOF homelab infrastructure. It explains what each tool does, why it was selected, and how it fits into the overall security-focused architecture defined in [GEMINI.md](../GEMINI.md).

---

## Table of Contents

- [Architecture Diagram](#architecture-diagram)
- [Core Infrastructure](#core-infrastructure)
  - [openSUSE MicroOS](#opensuse-microos)
  - [Podman](#podman)
- [Management & Orchestration](#management--orchestration)
  - [Homepage](#homepage)
  - [Dockge](#dockge)
  - [Traefik](#traefik)
- [Observability & Logging (LGV Stack)](#observability--logging-lgv-stack)
  - [Loki](#loki)
  - [Grafana](#grafana)
  - [Vector](#vector)
  - [Prometheus](#prometheus)
- [Security Operations Center (SOC)](#security-operations-center-soc)
  - [Wazuh](#wazuh)
  - [Falco](#falco)
  - [CrowdSec](#crowdsec)
  - [RamaLama](#ramalama)
  - [DefectDojo](#defectdojo)
- [Vulnerability Management & Compliance](#vulnerability-management--compliance)
  - [Trivy](#trivy)
  - [Grype](#grype)
  - [Dockle](#dockle)
  - [Checkov](#checkov)
  - [Terrascan](#terrascan)
  - [Gitleaks](#gitleaks)
- [Strategic Infrastructure](#strategic-infrastructure)
  - [Kanidm / Authelia](#kanidm--authelia)
  - [Harbor](#harbor)
  - [Step-CA](#step-ca)
  - [MinIO](#minio)

---

## Architecture Diagram

The following diagram illustrates how all components interact within the GEO-Brain homelab infrastructure. Edge labels describe what data flows between components.

```mermaid
graph TD
    USER(["User / Browser"])

    subgraph Host ["openSUSE MicroOS (STIG-Compliant, Immutable Host)"]

        subgraph HOST_MON ["Host-Level Monitoring (systemd services)"]
            JD["journald — captures all systemd<br/>unit and kernel log output"]
            AD["auditd — records syscall-level<br/>events for STIG audit trails"]
            TU["transactional-update — reports<br/>atomic OS update status & rollback health"]
        end

        subgraph Podman ["Podman (Rootless Container Engine — all stacks run unprivileged)"]

            subgraph MGMT ["Management & Orchestration"]
                TR["Traefik<br/>Reverse proxy that terminates TLS,<br/>routes *.example.local traffic,<br/>and enforces auth via middleware"]
                HP["Homepage<br/>Dashboard auto-discovers services<br/>via container labels and displays<br/>real-time health status"]
                DG["Dockge<br/>Visual Compose stack manager<br/>synced from Git for GitOps control"]
            end

            subgraph AUTH ["Identity & Access"]
                IAM["Kanidm / Authelia<br/>Centralized SSO + MFA provider;<br/>Traefik delegates all authn/authz here"]
            end

            subgraph SOC ["Security Operations Center (SOC)"]
                WZ["Wazuh (SIEM/XDR)<br/>Correlates all security events, runs<br/>threat-detection rules, and monitors<br/>compliance drift"]
                FL["Falco<br/>eBPF-based runtime monitor that<br/>detects anomalous syscalls inside<br/>containers (shell spawns, file access)"]
                CS["CrowdSec<br/>Behavioral IPS that analyzes Traefik<br/>access logs and pushes block<br/>decisions to its bouncer"]
                DD["DefectDojo<br/>Aggregates, deduplicates, and tracks<br/>vulnerability findings from all scanners"]
                RL["RamaLama<br/>Local LLM (air-gapped) that triages<br/>Wazuh alerts and DefectDojo findings<br/>to assist human operators"]
            end

            subgraph LGV ["Observability — LGV Stack"]
                VC["Vector<br/>High-performance log pipeline (Rust);<br/>collects, transforms, and routes<br/>all log data from host + containers"]
                LK["Loki<br/>Log aggregation engine; indexes<br/>metadata only for cost-efficient<br/>long-term storage on MinIO"]
                PR["Prometheus<br/>Scrapes /metrics endpoints from all<br/>containers and the host; stores<br/>time-series data for alerting"]
                GF["Grafana<br/>Unified dashboards querying Loki (logs),<br/>Prometheus (metrics), and Wazuh<br/>(security events) in one pane"]
            end

            subgraph SCAN ["Vulnerability Scanning Suite (scheduled / CI)"]
                TV["Trivy — image & filesystem CVE scanner"]
                GP["Grype — secondary CVE scanner (Anchore feed)"]
                DL["Dockle — image CIS benchmark linter"]
                CV["Checkov — IaC policy-as-code scanner"]
                TS["Terrascan — IaC scanner with OPA policies"]
                GL["Gitleaks — Git history secret detector"]
            end

            subgraph INFRA ["Strategic Infrastructure"]
                HB["Harbor<br/>Pull-through cache / local registry;<br/>mirrors external images for air-gap<br/>and runs Trivy on every push"]
                CA["Step-CA<br/>Internal ACME-compatible PKI that<br/>issues *.example.local TLS certs<br/>to Traefik automatically"]
                MO["MinIO<br/>S3-compatible object store backing<br/>Loki log retention and backups"]
            end
        end
    end

    %% ── User Access Flow ──
    USER -- "HTTPS request<br/>(*.example.local)" --> TR
    TR -- "ForwardAuth middleware<br/>checks session / MFA" --> IAM
    IAM -. "auth OK → pass-through" .-> TR
    TR -- "proxies to backend" --> HP & DG & GF & WZ & DD

    %% ── TLS & Registry Infrastructure ──
    CA -- "issues ACME certs<br/>(auto-renewed)" --> TR
    HB -- "serves pinned container<br/>images (digest-verified)" --> Podman

    %% ── Host Logs → Vector Pipeline ──
    JD -- "system + unit logs" --> VC
    AD -- "syscall audit events" --> VC
    TU -- "update status events" --> VC

    %% ── Vector Log Routing (fan-out) ──
    VC -- "structured logs<br/>(indexed by labels)" --> LK
    VC -- "security-relevant logs<br/>(auth failures, alerts)" --> WZ

    %% ── Runtime Security ──
    FL -- "eBPF syscall alerts<br/>(container context)" --> VC
    CS -- "reads access logs<br/>from Traefik" --> TR
    CS -. "pushes ban decisions<br/>to Traefik bouncer" .-> TR

    %% ── Observability Queries ──
    LK -- "log query API" --> GF
    PR -- "metrics query API" --> GF
    MO -- "S3 storage backend<br/>for log chunks" --> LK
    PR -- "scrapes /metrics" --> Podman

    %% ── Vulnerability Scan Results ──
    TV & GP & DL -- "image scan<br/>findings (SARIF/JSON)" --> DD
    CV & TS -- "IaC misconfig<br/>findings" --> DD
    GL -- "exposed secret<br/>findings" --> DD

    %% ── SOC Correlation ──
    DD -. "high-severity findings<br/>forwarded as alerts" .-> WZ
    RL -. "queries alerts for<br/>AI-assisted triage" .-> WZ
    RL -. "queries findings for<br/>prioritization advice" .-> DD
    WZ -- "security events" --> GF
```

> **Reading the diagram:** Solid arrows (`→`) represent active data flows during normal operation. Dashed arrows (`⇢`) represent on-demand, advisory, or conditional flows (e.g., AI triage queries, alert forwarding).

---

## Core Infrastructure

### openSUSE MicroOS

**What it is:** openSUSE MicroOS is an immutable, container-optimized Linux distribution designed for single-purpose servers.

**Why it's used:**
- **Immutable Filesystem:** The read-only root filesystem prevents unauthorized modifications, enhancing security posture.
- **Transactional Updates:** Uses `transactional-update` to apply atomic updates with automatic rollback capability if something fails.
- **Minimal Attack Surface:** Ships with only essential packages, reducing potential vulnerabilities.
- **STIG Alignment:** Its hardened nature aligns well with DISA Security Technical Implementation Guides (STIGs).

**Key Features:**
- Automatic rollback on failed updates
- Containerized workload focus
- SELinux support for mandatory access control

---

### Podman

**What it is:** Podman is a daemonless, rootless container engine that provides a Docker-compatible CLI and runtime.

**Why it's used:**
- **Rootless by Default:** Containers run without root privileges, significantly reducing the blast radius of container escapes.
- **Daemonless Architecture:** No persistent daemon means fewer attack vectors compared to Docker's daemon model.
- **Docker Compatibility:** Supports Docker Compose files via `podman-compose`, enabling easy migration from Docker.
- **Systemd Integration:** Native integration with systemd for container lifecycle management.
- **STIG Compliance:** Better aligns with security requirements by avoiding privileged operations.

**Security Benefits:**
```
Traditional Docker:     Podman (Rootless):
┌─────────────┐         ┌─────────────┐
│   Docker    │         │   User      │
│   Daemon    │         │  Process    │
│  (ROOT)     │         │ (Non-root)  │
└──────┬──────┘         └──────┬──────┘
       │                       │
┌──────▼──────┐         ┌──────▼──────┐
│  Container  │         │  Container  │
│  (Isolated) │         │  (Isolated) │
└─────────────┘         └─────────────┘
```

---

## Management & Orchestration

### Homepage

**What it is:** Homepage is a modern, self-hosted application dashboard that provides a unified view of all your services.

**Why it's used:**
- **Service Discovery:** Uses container labels to automatically discover and display services.
- **Centralized Access:** Provides a single entry point to navigate the homelab infrastructure.
- **Status Monitoring:** Shows real-time status of all deployed applications.
- **Customizable:** Supports widgets, bookmarks, and service integrations.

**Configuration Example:**

> **Note:** `${DOMAIN}` is an environment variable configured in the root `.env` file (default: `example.local`).

```yaml
labels:
  - "homepage.group=Security"
  - "homepage.name=Wazuh"
  - "homepage.href=https://wazuh.${DOMAIN}"
```

---

### Dockge

**What it is:** Dockge is a self-hosted Docker Compose stack manager with a beautiful UI.

**Why it's used:**
- **Visual Stack Management:** Provides an intuitive interface for managing Docker Compose stacks.
- **Git Integration:** Stacks can be synced from this repository, maintaining GitOps principles.
- **Real-time Logs:** View container logs directly from the UI.
- **YAML Editing:** Built-in editor for compose files with syntax highlighting.

**Integration with GEO-Brain:**
- All stacks in this repository are managed through Dockge
- Changes are synced from Git to ensure version control
- Provides visual feedback on stack health and status

---

### Traefik

**What it is:** Traefik is a modern HTTP reverse proxy and load balancer designed for containerized environments.

**Why it's used:**
- **Dynamic Configuration:** Automatically discovers services via Podman labels.
- **TLS Termination:** Manages internal TLS certificates issued by Step-CA.
- **SSO Integration:** Forwards authentication requests to Authelia for centralized SSO.
- **Rootless Compatible:** Runs efficiently in a rootless Podman environment.

**Protection Workflow:**
```
User → Traefik (TLS) → Authelia (MFA) → Backend Service
```

---

## Observability & Logging (LGV Stack)

### Loki

**What it is:** Loki is a horizontally scalable, highly available, multi-tenant log aggregation system inspired by Prometheus.

**Why it's used:**
- **Efficient Indexing:** Indexes only metadata, not the full log content, significantly reducing storage costs.
- **Prometheus Integration:** Shares labeling strategies with Prometheus, enabling seamless transitions between metrics and logs.
- **MinIO Storage:** Uses MinIO (S3) for durable, long-term log storage.

---

### Grafana

**What it is:** Grafana is the open-source platform for monitoring and observability.

**Why it's used:**
- **Unified Visualization:** Combines metrics (Prometheus), logs (Loki), and security events (Wazuh) into a single dashboard.
- **Advanced Alerting:** Provides a robust alerting engine for all data sources.
- **Customizable Dashboards:** Supports community-sourced dashboards for all infrastructure components.

---

### Vector

**What it is:** Vector is a high-performance, observability data pipeline that collect, transform, and route all your logs and metrics.

**Why it's used:**
- **Log Unification:** Collects logs from `journald`, Podman containers, and system files.
- **Transformation:** Normalizes logs before forwarding to Loki or Wazuh.
- **Reliability:** Built in Rust for memory safety and high performance.
- **STIG Compliance:** Replaces legacy log forwarders with a more secure, modern alternative.

---

### Prometheus

**What it is:** Prometheus is an open-source systems monitoring and alerting toolkit.

**Why it's used:**
- **Metrics Collection:** Scrapes metrics from all containers and the host OS.
- **Time-Series Database:** Optimized for storing high-cardinality monitoring data.
- **Alertmanager:** Handles alerts generated by client applications and forwards them to the SOC.

---

## Security Operations Center (SOC)

### Wazuh

**What it is:** Wazuh is an open-source SIEM (Security Information and Event Management) and XDR (Extended Detection and Response) platform.

**Why it's used:**
- **Centralized Log Management:** Aggregates logs from all sources for unified analysis.
- **Threat Detection:** Uses rules and decoders to identify security threats in real-time.
- **Compliance Monitoring:** Built-in modules for monitoring STIG and CIS compliance.
- **File Integrity Monitoring:** Detects unauthorized changes to critical system files.
- **Vulnerability Detection:** Integrates vulnerability data with endpoint information.

**Key Components:**
| Component | Purpose |
|-----------|---------|
| Wazuh Manager | Analyzes events and generates alerts |
| Wazuh Indexer | Stores and indexes security data |
| Wazuh Dashboard | Web interface for visualization |

---

### Falco

**What it is:** Falco is a cloud-native runtime security tool that detects anomalous activity in containers and hosts.

**Why it's used:**
- **Runtime Detection:** Monitors system calls in real-time to detect suspicious behavior.
- **Container-Aware:** Understands container context and can detect container-specific threats.
- **Custom Rules:** Supports custom rules for organization-specific security policies.
- **Wazuh Integration:** Forwards alerts to Wazuh for centralized analysis.

**Detection Examples:**
- Shell spawned inside a container
- Sensitive file access (e.g., `/etc/shadow`)
- Network connections from unexpected processes
- Privilege escalation attempts

---

### CrowdSec

**What it is:** CrowdSec is a collaborative intrusion prevention system that detects and blocks malicious behavior.

**Why it's used:**
- **Behavioral Detection:** Analyzes logs to detect malicious patterns.
- **Bouncer Architecture:** Integrates with firewalls, reverse proxies (Traefik), and applications.
- **Podman Compatible:** Works well with containerized deployments.

---

### RamaLama

**What it is:** RamaLama is an AI-powered log analysis tool that uses lightweight Large Language Models (LLMs) to evaluate security alerts.

**Why it's used:**
- **AI-Assisted Triage:** Helps human operators prioritize security alerts from Wazuh and DefectDojo.
- **Air-Gapped Operation:** Runs locally without internet connectivity, ensuring no data exfiltration.
- **Lightweight Models:** Uses efficient models like Phi-3 Mini that run on modest hardware.

---

### DefectDojo

**What it is:** DefectDojo is an open-source vulnerability management platform that correlates and tracks security findings.

**Why it's used:**
- **Unified View:** Aggregates findings from multiple security tools (Trivy, Grype, OpenSCAP, etc.).
- **Deduplication:** Automatically identifies and merges duplicate findings.
- **Trend Analysis:** Tracks vulnerability metrics over time.
- **Workflow Management:** Assigns findings to team members and tracks remediation.

---

## Vulnerability Management & Compliance

### Trivy

**What it is:** Trivy is a comprehensive security scanner that detects vulnerabilities, misconfigurations, secrets, and license issues.

**Why it's used:**
- **Multi-Target:** Scans container images, filesystems, Git repositories, and IaC files.
- **Comprehensive Database:** Maintains an extensive CVE database with fast updates.
- **Air-Gap Support:** Can operate with locally cached vulnerability databases.

---

### Grype

**What it is:** Grype is an open-source vulnerability scanner focused on container images and filesystems.

**Why it's used:**
- **Anchore Database:** Leverages Anchore's comprehensive vulnerability feed.
- **Alternative Perspective:** Provides a second opinion alongside Trivy for thorough coverage.

---

### Dockle

**What it is:** Dockle is a container image linter that checks for security best practices and CIS benchmarks.

**Why it's used:**
- **Best Practices:** Validates images against container security best practices.
- **CIS Benchmark:** Checks compliance with CIS Docker Benchmark guidelines.

---

### Checkov

**What it is:** Checkov is a static code analysis tool for Infrastructure-as-Code (IaC) security.

**Why it's used:**
- **IaC Security:** Scans Docker Compose, Terraform, Kubernetes, and other IaC formats.
- **Policy-as-Code:** Supports custom policies written in Python or YAML.

---

### Terrascan

**What it is:** Terrascan is a static code analyzer for IaC security that supports multiple policy engines.

**Why it's used:**
- **Multi-Cloud:** Supports AWS, Azure, GCP, and Kubernetes configurations.
- **OPA Integration:** Uses Open Policy Agent (OPA) for policy enforcement.

---

### Gitleaks

**What it is:** Gitleaks is a SAST tool for detecting secrets, passwords, and API keys in Git repositories.

**Why it's used:**
- **Secret Prevention:** Catches hardcoded credentials before they reach production.
- **Historical Scanning:** Can scan entire Git history for exposed secrets.

---

## Strategic Infrastructure

### Kanidm / Authelia

**What they are:** 
- **Kanidm:** A modern, secure identity management system written in Rust.
- **Authelia:** An open-source authentication and authorization server.

**Why they're used:**
- **Centralized IAM:** Provides single sign-on (SSO) for all web interfaces.
- **Multi-Factor Authentication:** Enforces MFA for enhanced security.
- **Access Control:** Implements role-based access control (RBAC) for services.

---

### Harbor

**What it is:** Harbor is an open-source container registry that provides security and compliance features.

**Why it's used:**
- **Local Registry:** Caches container images for air-gapped operation.
- **Pull-Through Cache:** Mirrors external registries to reduce external dependencies.
- **Vulnerability Scanning:** Integrates Trivy for automatic image scanning.

---

### Step-CA

**What it is:** Step-CA is a private certificate authority for issuing internal TLS certificates.

**Why it's used:**
- **Internal PKI:** Issues certificates for `*.example.local` domain.
- **ACME Support:** Supports automatic certificate issuance via ACME protocol.

---

### MinIO

**What it is:** MinIO is a high-performance, S3-compatible object storage server.

**Why it's used:**
- **Backend Storage:** Provides persistent storage for Loki logs and backups.
- **S3 Compatibility:** Works with any application that supports S3-compliant storage.
- **Scalability:** Can be scaled horizontally to meet increasing storage needs.

---

## Summary: Tool Categories

| Category | Tools | Purpose |
|----------|-------|---------|
| **Host OS** | openSUSE MicroOS | Immutable, hardened container host |
| **Container Engine** | Podman | Rootless container runtime |
| **Orchestration** | Traefik, Homepage | Proxy, Dashboard, and Management |
| **Stack Mgmt** | Dockge | Docker Compose stack management |
| **AI Analysis** | RamaLama | Intelligent log triage |
| **SIEM/XDR** | Wazuh | Security event management |
| **Log Pipeline** | Vector | Log collection and forwarding |
| **Runtime Security** | Falco | Real-time threat detection |
| **Vuln Management** | DefectDojo | Finding aggregation and tracking |
| **Image Scanning** | Trivy, Grype | CVE detection |
| **Image Linting** | Dockle | Best practice validation |
| **IaC Scanning** | Checkov, Terrascan | Configuration security |
| **Secret Detection** | Gitleaks | Credential leak prevention |
| **Identity** | Kanidm, Authelia | Authentication and authorization |
| **Registry** | Harbor | Image caching and scanning |
| **PKI** | Step-CA | Internal certificate authority |
| **IPS** | CrowdSec | Intrusion prevention |
| **Storage** | MinIO | S3-compatible object storage |

---

## Further Reading

- [DISA STIGs](https://public.cyber.mil/stigs/) - Official STIG documentation
- [Podman Documentation](https://docs.podman.io/) - Rootless container runtime
- [Wazuh Documentation](https://documentation.wazuh.com/) - SIEM/XDR platform
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/) - Security configuration guides
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework) - Cybersecurity standards

---

*This document is part of the GEO-Brain SSOF (Single Source of Truth) repository. For architectural mandates and system requirements, see [GEMINI.md](../GEMINI.md).*
