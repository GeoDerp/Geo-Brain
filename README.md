<p align="center">
  <img src="./docs/logo.svg" alt="GEO-Brain SSOF Logo" width="128"/>
</p>

# GEO-Brain SSOF: Single Node Homelab

This repository serves as the Single Source of Truth (SSOT) for a DISA STIG compliant, single-node homelab. It leverages Podman (rootless by default) and Docker Compose to manage an Infrastructure-as-Code application stack.

For comprehensive architectural mandates, system security guidelines, and the core philosophy driving this implementation, refer to the **[GEMINI.md](./GEMINI.md)** document.

---

## Scope: Deployment & Monitoring, Not GitOps

> **This is not a GitOps or DevSecOps CI/CD pipeline.**

This repository does **not** build, scan, or push container images. There is no `build → scan → push → deploy` automation cycle here. Instead, this repo:

- **Pulls pre-built images** from public or private container registries (e.g., Docker Hub, GHCR, Harbor)
- **Deploys and configures** those existing containers on a single node using Podman + Compose
- **Monitors and audits** the running environment using a security-focused tool stack (Wazuh, Falco, CrowdSec, etc.)

If you are looking for a full DevSecOps GitOps pipeline with image building, SBOM generation, registry signing, and automated rollouts, this repository is out of scope for that pattern. The focus here is on **operational security** — hardening, observability, and incident response for already-deployed workloads.

---

## Understanding the Tools

New to security-focused homelabs or want a deeper understanding of why specific tools were chosen? Check out our **[Tools Explained](./docs/TOOLS_EXPLAINED.md)** documentation which provides:

- **Detailed explanations** of every tool used in this infrastructure
- **Visual architecture diagrams** showing how components interact
- **Security rationale** for each technology choice
- **Practical examples** of how tools integrate together

This educational resource is designed to help both newcomers and experienced practitioners understand the security-first approach of this homelab.

---

## Directory Structure

- **`.env`**: The global environment variables file containing the primary `DOMAIN` configuration.
- **`deploy.sh`**: A wrapper script to validate and deploy stacks reliably via `podman-compose`. Automatically detects whether to deploy locally or to a remote node (configured by `init-node.sh`).
- **`init-node.sh`**: Provisions a remote homelab node via SSH (Podman, `podman.socket`, `auditd`, firewalld, networks)  using ansible playbook and configures the local workstation for `podman-remote` access.
- **`stacks/`**: Contains the Docker Compose files and respective data/configuration directories for each application.
- **`stacks/user/`**: (Git-ignored) A dedicated directory for user-specific stacks. Applications placed here will not be committed to the repository, allowing for local experimentation or personal tools (e.g., note-taking, private dashboards) while still leveraging the `deploy.sh` and `init-node.sh` infrastructure.
- **`scripts/`**: Houses utility scripts, including security auditing tools (`sast/`).
- **`docs/`**: Educational documentation explaining the tools and architecture used in this project.

## Stacks

The infrastructure is broken down into modular stacks, all utilizing rootless Podman where possible:

- **Management & Observability:** Homepage, Dockge
- **Security Operations Center (SOC):** Wazuh, Falco, DefectDojo, **RamaLama (AI Analysis)**
- **Core Security Infrastructure:** Vaultwarden (Secrets), Kanidm (Identity), Step-CA (Internal PKI), Harbor (Registry), CrowdSec (Intrusion Prevention)

### Optional Stacks (WIP)

These stacks are **not deployed by default** and serve as drop-in enhancements for specific use cases:

- **Pangolin (Zero-Trust Tunnel Proxy):** Identity-aware reverse proxy and WireGuard VPN for secure remote access without exposing ports or requiring a public IP. Replaces Traefik + Authelia when tunnel-based access is needed. *(AGPL-3.0, fosrl/pangolin)*
- **BunkerWeb (L7 WAF & DDoS Protection):** Next-generation Web Application Firewall based on NGINX with integrated ModSecurity + OWASP Core Rule Set, rate limiting, anti-bot challenges, IP blacklists, DNSBL, and CrowdSec integration. Sits in front of Traefik as an L7 security perimeter. *(AGPL-3.0, bunkerity/bunkerweb)*

> **Note:** Pangolin bundles its own Traefik instance and **cannot** run alongside the existing Traefik stack. BunkerWeb requires Traefik to move to internal-only ports when deployed as the external-facing WAF.

---

## Configuration

All stacks are configured dynamically using variables defined in the root `.env` file. This prevents the exposure of personal domains or secrets within the static `docker-compose.yml` configurations.

### 1. Set the Domain

Edit the root `.env` file to match your desired top-level homelab domain. All applications and their respective `homepage.href` labels will automatically reflect this base domain during deployment.

```dotenv
# .env
DOMAIN=example.local
```

### 2. Configure Application Secrets

By default, the stacks are templated with placeholders. Before deploying to production, ensure that you provide secure credentials in individual stack configurations. 

*Note: Avoid committing any `.env` files with real credentials to source control.*

---

## Deployment Instructions

### Prerequisites

- A remote homelab node running **openSUSE MicroOS**, **Fedora CoreOS**, or **Fedora Server**.
- **SSH key-based authentication** configured for the remote node.
- **Podman** installed on your local workstation (for `podman system connection`).
- **Ansible** installed on your local workstation (required by `init-node.sh` for initial provisioning only):
  ```bash
  # Fedora / RHEL
  sudo dnf install ansible-core

  # pip (any distro)
  pip install ansible-core

  # Also install the required collection
  ansible-galaxy collection install ansible.posix
  ```

### 1. Initialize the Homelab Node

Run `init-node.sh` from your **local workstation** (not on the remote node). It will:

1. **Prompt** for the homelab's IP address, SSH user, and SSH key path (or accept them via flags).
2. **SSH into the remote node** and provision it — installing Podman, enabling `podman.socket`, configuring `auditd`, `firewalld`, SELinux, rootless `subuids`, `vm.max_map_count`, user linger, and the mandatory Podman networks.
3. **Register a local `podman system connection`** so your workstation can talk to the remote node via `podman-remote`.
4. **Save connection details** to `.env` for use by `deploy.sh`.

```bash
# Interactive (prompts for IP, user, key)
./init-node.sh

# Or pass flags directly
./init-node.sh --host 192.168.1.100 --user geo --key ~/.ssh/id_ed25519

# Verify the connection
podman --connection homelab ps
```

### 2. Deploy a Stack

Once `init-node.sh` has configured the remote connection, `deploy.sh` automatically syncs stack files to the remote node and runs `podman compose` via SSH.

**Usage:**
```bash
./deploy.sh [stack-name] [command]
```

**Examples:**
```bash
# Bring up the 'homepage' stack on the remote node
./deploy.sh homepage up

# View logs for 'wazuh'
./deploy.sh wazuh logs

# Tear down the 'dockge' stack
./deploy.sh dockge down

# Deploy all base infrastructure stacks
./deploy.sh base up

# Run STIG validation only (no deployment)
./deploy.sh harbor check
```

> **Local mode fallback:** If `REMOTE_HOST` is not set in `.env` (i.e., `init-node.sh` hasn't been run), `deploy.sh` operates locally against the current machine.

---

## AI-Driven Log Analysis

This repository includes a lightweight LLM stack powered by **RamaLama** to assist human operators in evaluating complex security outputs from Wazuh and DefectDojo.

### 1. Deploy the LLM Stack

```bash
./deploy.sh ramalama up
```
This will serve an OpenAI-compatible API using the `phi3:mini` model at `http://${DOMAIN}:8084`.

### 2. Evaluate Security Data

Use the provided analysis script to send JSON data or log files to the LLM for summarization and prioritization:

```bash
# Example: Evaluate a DefectDojo report
./scripts/analysis/analyze_security.py DefectDojo /path/to/report.json

# Example: Evaluate a Wazuh alert
./scripts/analysis/analyze_security.py Wazuh /path/to/alert.log
```

---

## Security & Compliance Scanning

As part of the repository's security mandates, you can run offline Static Application Security Testing (SAST) against the deployed stacks to audit IaC configurations, code quality, and potential secret exposures.

The integrated suite includes:
- **Trivy / Checkov:** Infrastructure-as-Code (IaC) misconfiguration and image vulnerability scanning.
- **Semgrep:** High-speed static analysis for code and configuration security.
- **Gitleaks:** Continuous secret detection across the repository.

Ensure you have the required tools installed, then run:

```bash
# Scan a specific stack
./scripts/sast/sast-scan.sh harbor

# Scan all stacks
./scripts/sast/sast-scan.sh all
```

---
**Note:** Ensure all data persistence directories (`./data`) have appropriate permissions (e.g., `1000:1000`) to match the user namespace mapping within the rootless Podman containers.
