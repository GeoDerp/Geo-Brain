# GEO-Brain Tools: A Deep Dive

This document provides an educational overview of all tools and technologies used in the GEO-Brain homelab infrastructure. It explains what each tool does, why it was selected, and how it fits into the overall security-focused architecture defined in [GEMINI.md](../GEMINI.md).

---

## Table of Contents

- [Architecture Diagram](#architecture-diagram)
- [Core Infrastructure](#core-infrastructure)
  - [openSUSE MicroOS](#opensuse-microos)
  - [Podman](#podman)
- [Management & Observability](#management--observability)
  - [Homepage](#homepage)
  - [Dockge](#dockge)
  - [RamaLama](#ramalama)
- [Security Operations Center (SOC)](#security-operations-center-soc)
  - [Wazuh](#wazuh)
  - [Fluent-bit](#fluent-bit)
  - [Falco](#falco)
  - [OpenSCAP](#openscap)
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
  - [Vaultwarden](#vaultwarden)
  - [Harbor](#harbor)
  - [Step-CA](#step-ca)
  - [CrowdSec](#crowdsec)

---

## Architecture Diagram

The following diagram illustrates how all components interact within the GEO-Brain homelab infrastructure:

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              GEO-BRAIN HOMELAB ARCHITECTURE                             │
│                           openSUSE MicroOS (STIG Compliant Host)                        │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                           PODMAN (Rootless Container Engine)                    │   │
│  ├─────────────────────────────────────────────────────────────────────────────────┤   │
│  │                                                                                 │   │
│  │  ┌──────────────────────────────┐    ┌──────────────────────────────────────┐  │   │
│  │  │   MANAGEMENT & OBSERVABILITY │    │     SECURITY OPERATIONS CENTER       │  │   │
│  │  │  ┌─────────┐  ┌─────────┐    │    │                                      │  │   │
│  │  │  │Homepage │  │ Dockge  │    │    │  ┌────────────────────────────────┐  │  │   │
│  │  │  │(Dashboard)│ │(Stack Mgr)│  │    │  │           WAZUH (SIEM/XDR)     │  │  │   │
│  │  │  └─────────┘  └─────────┘    │    │  │  ┌──────────┐    ┌──────────┐  │  │  │   │
│  │  │       │             │        │    │  │  │ Indexer  │    │Dashboard │  │  │  │   │
│  │  │  ┌────▼─────────────▼────┐   │    │  │  └──────────┘    └──────────┘  │  │  │   │
│  │  │  │      RamaLama         │   │    │  └───────────────▲────────────────┘  │  │   │
│  │  │  │  (AI Log Analysis)    │   │    │                  │                   │  │   │
│  │  │  │  ┌──────────────┐     │   │    │   ┌──────────────┴─────────────┐     │  │   │
│  │  │  │  │ Phi-3 Model  │     │   │───▶│   │        Fluent-bit         │     │  │   │
│  │  │  │  └──────────────┘     │   │    │   │     (Log Forwarding)      │     │  │   │
│  │  │  └───────────────────────┘   │    │   └───────────────────────────┘     │  │   │
│  │  └──────────────────────────────┘    │                  ▲                   │  │   │
│  │                                      │   ┌──────────────┴─────────────┐     │  │   │
│  │                                      │   │          Falco             │     │  │   │
│  │                                      │   │  (Runtime Security)        │     │  │   │
│  │                                      │   └────────────────────────────┘     │  │   │
│  │                                      │                                      │  │   │
│  │                                      │   ┌────────────────────────────┐     │  │   │
│  │                                      │   │        DefectDojo          │     │  │   │
│  │                                      │   │  (Vulnerability Mgmt)      │◀────│──│───┤
│  │                                      │   └────────────────────────────┘     │  │   │
│  │                                      └──────────────────────────────────────┘  │   │
│  │                                                                                 │   │
│  │  ┌──────────────────────────────┐    ┌──────────────────────────────────────┐  │   │
│  │  │ VULNERABILITY SCANNING SUITE │    │    STRATEGIC INFRASTRUCTURE          │  │   │
│  │  │                              │    │                                      │  │   │
│  │  │ ┌───────┐ ┌───────┐ ┌──────┐│    │ ┌────────────┐   ┌──────────────┐    │  │   │
│  │  │ │ Trivy │ │ Grype │ │Dockle││    │ │  Kanidm/   │   │  Vaultwarden │    │  │   │
│  │  │ │(CVEs) │ │(CVEs) │ │(Lint)││    │ │  Authelia  │   │  (Secrets)   │    │  │   │
│  │  │ └───┬───┘ └───┬───┘ └──┬───┘│    │ │   (IAM)    │   └──────────────┘    │  │   │
│  │  │     │         │        │    │    │ └────────────┘                       │  │   │
│  │  │ ┌───▼─────────▼────────▼──┐ │    │ ┌────────────┐   ┌──────────────┐    │  │   │
│  │  │ │       DefectDojo        │ │    │ │   Harbor   │   │   Step-CA    │    │  │   │
│  │  │ │   (Unified Reporting)   │ │    │ │ (Registry) │   │ (Int. PKI)   │    │  │   │
│  │  │ └─────────────────────────┘ │    │ └────────────┘   └──────────────┘    │  │   │
│  │  │                              │    │                                      │  │   │
│  │  │ ┌────────┐ ┌─────────┐      │    │ ┌────────────────────────────────┐   │  │   │
│  │  │ │Checkov │ │Terrascan│      │    │ │          CrowdSec              │   │  │   │
│  │  │ │ (IaC)  │ │  (IaC)  │      │    │ │    (Intrusion Prevention)      │   │  │   │
│  │  │ └────────┘ └─────────┘      │    │ └────────────────────────────────┘   │  │   │
│  │  │                              │    │                                      │  │   │
│  │  │ ┌────────────────────────┐  │    │ ┌────────────────────────────────┐   │  │   │
│  │  │ │       Gitleaks         │  │    │ │         OpenSCAP               │   │  │   │
│  │  │ │   (Secret Detection)   │  │    │ │    (STIG Compliance)           │   │  │   │
│  │  │ └────────────────────────┘  │    │ └────────────────────────────────┘   │  │   │
│  │  └──────────────────────────────┘    └──────────────────────────────────────┘  │   │
│  │                                                                                 │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                              HOST-LEVEL MONITORING                              │   │
│  │                                                                                 │   │
│  │   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────────────┐   │   │
│  │   │     journald     │   │     auditd       │   │  transactional-update    │   │   │
│  │   │  (System Logs)   │   │ (Syscall Audit)  │   │   (OS Update Status)     │   │   │
│  │   └──────────────────┘   └──────────────────┘   └──────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

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

## Management & Observability

### Homepage

**What it is:** Homepage is a modern, self-hosted application dashboard that provides a unified view of all your services.

**Why it's used:**
- **Service Discovery:** Uses container labels to automatically discover and display services.
- **Centralized Access:** Provides a single entry point to navigate the homelab infrastructure.
- **Status Monitoring:** Shows real-time status of all deployed applications.
- **Customizable:** Supports widgets, bookmarks, and service integrations.

**Configuration Example:**
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

### RamaLama

**What it is:** RamaLama is an AI-powered log analysis tool that uses lightweight Large Language Models (LLMs) to evaluate security alerts.

**Why it's used:**
- **AI-Assisted Triage:** Helps human operators prioritize security alerts from Wazuh and DefectDojo.
- **Air-Gapped Operation:** Runs locally without internet connectivity, ensuring no data exfiltration.
- **Lightweight Models:** Uses efficient models like Phi-3 Mini that run on modest hardware.
- **OpenAI-Compatible API:** Easy integration with existing tooling and scripts.

**Use Case:**
```bash
# Analyze a Wazuh alert using the local LLM
./scripts/analysis/analyze_security.py Wazuh /path/to/alert.log
```

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

### Fluent-bit

**What it is:** Fluent-bit is a lightweight log processor and forwarder designed for high-throughput environments.

**Why it's used:**
- **Journald Integration:** Collects logs from systemd's journald on the host.
- **Low Resource Usage:** Minimal memory footprint compared to alternatives like Fluentd.
- **Flexible Routing:** Can parse, filter, and route logs to multiple destinations.
- **Wazuh Integration:** Forwards processed logs to Wazuh for security analysis.

**Data Flow:**
```
journald → Fluent-bit → Wazuh Manager → Analysis/Alerting
```

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

### OpenSCAP

**What it is:** OpenSCAP is an ecosystem for Security Content Automation Protocol (SCAP) compliance checking.

**Why it's used:**
- **STIG Compliance:** Validates systems against DISA STIGs (Security Technical Implementation Guides).
- **Automated Scanning:** Runs periodic compliance checks on host and containers.
- **Detailed Reports:** Generates comprehensive reports showing compliance status.
- **DefectDojo Integration:** Results can be imported into DefectDojo for unified reporting.

**Compliance Flow:**
```
OpenSCAP Scan → SCAP Results (XML/HTML) → DefectDojo Import → Unified Dashboard
```

---

### DefectDojo

**What it is:** DefectDojo is an open-source vulnerability management platform that correlates and tracks security findings.

**Why it's used:**
- **Unified View:** Aggregates findings from multiple security tools (Trivy, Grype, OpenSCAP, etc.).
- **Deduplication:** Automatically identifies and merges duplicate findings.
- **Trend Analysis:** Tracks vulnerability metrics over time.
- **Integration Hub:** Supports importing results from 150+ security tools.
- **Workflow Management:** Assigns findings to team members and tracks remediation.

**Data Sources:**
- Trivy/Grype CVE scans
- Checkov/Terrascan IaC findings
- Gitleaks secret detections
- OpenSCAP compliance results
- Falco runtime alerts

---

## Vulnerability Management & Compliance

### Trivy

**What it is:** Trivy is a comprehensive security scanner that detects vulnerabilities, misconfigurations, secrets, and license issues.

**Why it's used:**
- **Multi-Target:** Scans container images, filesystems, Git repositories, and IaC files.
- **Comprehensive Database:** Maintains an extensive CVE database with fast updates.
- **Air-Gap Support:** Can operate with locally cached vulnerability databases.
- **CI/CD Integration:** Easy to integrate into automated pipelines.

**Scan Types:**
| Target | What It Scans |
|--------|---------------|
| Image | Container image layers for vulnerabilities |
| Filesystem | Local directories for vulnerabilities and secrets |
| Repository | Git repos for misconfigurations and secrets |
| Config | IaC files (Terraform, Kubernetes, Docker) |

---

### Grype

**What it is:** Grype is an open-source vulnerability scanner focused on container images and filesystems.

**Why it's used:**
- **Anchore Database:** Leverages Anchore's comprehensive vulnerability feed.
- **Alternative Perspective:** Provides a second opinion alongside Trivy for thorough coverage.
- **SBOM Integration:** Works with Software Bill of Materials (SBOM) generated by Syft.
- **Fast Scanning:** Optimized for quick scans with accurate results.

**Why Use Both Trivy and Grype:**
Different vulnerability databases may catch different CVEs. Using both ensures more comprehensive coverage.

---

### Dockle

**What it is:** Dockle is a container image linter that checks for security best practices and CIS benchmarks.

**Why it's used:**
- **Best Practices:** Validates images against container security best practices.
- **CIS Benchmark:** Checks compliance with CIS Docker Benchmark guidelines.
- **Build-Time Security:** Catches issues before images are deployed.

**Common Checks:**
- Running as non-root user
- No sensitive files in image
- Proper health checks defined
- No hardcoded secrets

---

### Checkov

**What it is:** Checkov is a static code analysis tool for Infrastructure-as-Code (IaC) security.

**Why it's used:**
- **IaC Security:** Scans Docker Compose, Terraform, Kubernetes, and other IaC formats.
- **Policy-as-Code:** Supports custom policies written in Python or YAML.
- **Misconfiguration Detection:** Identifies security misconfigurations before deployment.
- **Compliance Frameworks:** Maps findings to compliance standards (CIS, SOC2, etc.).

**Supported Formats:**
- Docker Compose files
- Dockerfiles
- Kubernetes manifests
- Terraform configurations

---

### Terrascan

**What it is:** Terrascan is a static code analyzer for IaC security that supports multiple policy engines.

**Why it's used:**
- **Multi-Cloud:** Supports AWS, Azure, GCP, and Kubernetes configurations.
- **OPA Integration:** Uses Open Policy Agent (OPA) for policy enforcement.
- **Alternative to Checkov:** Provides additional coverage with different rule sets.
- **CI/CD Friendly:** Designed for automated pipeline integration.

---

### Gitleaks

**What it is:** Gitleaks is a SAST tool for detecting secrets, passwords, and API keys in Git repositories.

**Why it's used:**
- **Secret Prevention:** Catches hardcoded credentials before they reach production.
- **Historical Scanning:** Can scan entire Git history for exposed secrets.
- **Pre-Commit Hook:** Can be used as a pre-commit hook to prevent secret commits.
- **Custom Rules:** Supports custom patterns for organization-specific secrets.

**Protected Secret Types:**
- API keys (AWS, Azure, GCP, etc.)
- Database passwords
- Private keys and certificates
- OAuth tokens
- Generic passwords and credentials

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
- **LDAP/OIDC Support:** Integrates with applications via standard protocols.

**Authentication Flow:**
```
User → Authelia/Kanidm → MFA Challenge → Authenticated Session → Application
```

---

### Vaultwarden

**What it is:** Vaultwarden is a lightweight, self-hosted Bitwarden-compatible password manager.

**Why it's used:**
- **Secret Storage:** Securely stores application credentials and secrets.
- **Encrypted Database:** All data is encrypted at rest.
- **Browser Extensions:** Compatible with Bitwarden browser extensions and apps.
- **No Cloud Dependency:** Operates entirely locally, supporting air-gapped environments.

**Security Mandate:**
> No plain-text secrets should exist in this repository. All credentials must be stored in Vaultwarden.

---

### Harbor

**What it is:** Harbor is an open-source container registry that provides security and compliance features.

**Why it's used:**
- **Local Registry:** Caches container images for air-gapped operation.
- **Pull-Through Cache:** Mirrors external registries to reduce external dependencies.
- **Vulnerability Scanning:** Integrates Trivy for automatic image scanning.
- **Access Control:** Provides project-based access control for images.
- **Image Signing:** Supports content trust via Notary for image verification.

**Air-Gap Workflow:**
```
Internet → Harbor (Pull-Through Cache) → Internal Network → Podman
```

---

### Step-CA

**What it is:** Step-CA is a private certificate authority for issuing internal TLS certificates.

**Why it's used:**
- **Internal PKI:** Issues certificates for `*.example.local` domain.
- **ACME Support:** Supports automatic certificate issuance via ACME protocol.
- **Short-Lived Certificates:** Can issue short-lived certificates for enhanced security.
- **No External Dependencies:** Removes reliance on external CAs like Let's Encrypt.

**Certificate Hierarchy:**
```
Step-CA Root Certificate
    └── Intermediate CA
        ├── *.example.local
        ├── wazuh.example.local
        └── harbor.example.local
```

---

### CrowdSec

**What it is:** CrowdSec is a collaborative intrusion prevention system that detects and blocks malicious behavior.

**Why it's used:**
- **Behavioral Detection:** Analyzes logs to detect malicious patterns.
- **Community Intelligence:** (Optional) Shares threat intelligence with the community.
- **Bouncer Architecture:** Integrates with firewalls, reverse proxies, and applications.
- **Podman Compatible:** Works well with containerized deployments.

**Protection Mechanisms:**
- Brute-force attack mitigation
- HTTP flood protection
- Port scan detection
- Bad bot blocking

**Architecture:**
```
Logs → CrowdSec Agent → Decision Engine → Bouncers → Block/Allow
```

---

## Summary: Tool Categories

| Category | Tools | Purpose |
|----------|-------|---------|
| **Host OS** | openSUSE MicroOS | Immutable, hardened container host |
| **Container Engine** | Podman | Rootless container runtime |
| **Management** | Homepage, Dockge | Dashboard and stack management |
| **AI Analysis** | RamaLama | Intelligent log triage |
| **SIEM/XDR** | Wazuh | Security event management |
| **Log Pipeline** | Fluent-bit | Log collection and forwarding |
| **Runtime Security** | Falco | Real-time threat detection |
| **Compliance** | OpenSCAP | STIG compliance scanning |
| **Vuln Management** | DefectDojo | Finding aggregation and tracking |
| **Image Scanning** | Trivy, Grype | CVE detection |
| **Image Linting** | Dockle | Best practice validation |
| **IaC Scanning** | Checkov, Terrascan | Configuration security |
| **Secret Detection** | Gitleaks | Credential leak prevention |
| **Identity** | Kanidm, Authelia | Authentication and authorization |
| **Secrets** | Vaultwarden | Credential management |
| **Registry** | Harbor | Image caching and scanning |
| **PKI** | Step-CA | Internal certificate authority |
| **IPS** | CrowdSec | Intrusion prevention |

---

## Further Reading

- [DISA STIGs](https://public.cyber.mil/stigs/) - Official STIG documentation
- [Podman Documentation](https://docs.podman.io/) - Rootless container runtime
- [Wazuh Documentation](https://documentation.wazuh.com/) - SIEM/XDR platform
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/) - Security configuration guides
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework) - Cybersecurity standards

---

*This document is part of the GEO-Brain Single Source of Truth repository. For architectural mandates and system requirements, see [GEMINI.md](../GEMINI.md).*
