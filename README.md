# GEO-Brain SSOF: Single Node Homelab

This repository serves as the Single Source of Truth (SSOT) for a DISA STIG compliant, single-node homelab. It leverages Podman (rootless by default) and Docker Compose to manage an Infrastructure-as-Code application stack.

For comprehensive architectural mandates, system security guidelines, and the core philosophy driving this implementation, refer to the **[GEMINI.md](./GEMINI.md)** document.

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
- **`deploy.sh`**: A wrapper script to validate and deploy stacks reliably via `podman-compose`.
- **`init-node.sh`**: Bootstraps the host node (eg. openSUSE MicroOS) for remote Podman access and security auditing.
- **`stacks/`**: Contains the Docker Compose files and respective data/configuration directories for each application.
- **`stacks/user/`**: (Git-ignored) A dedicated directory for user-specific stacks. Applications placed here will not be committed to the repository, allowing for local experimentation or personal tools (e.g., note-taking, private dashboards) while still leveraging the `deploy.sh` and `init-node.sh` infrastructure.
- **`scripts/`**: Houses utility scripts, including security auditing tools (`sast/`).
- **`docs/`**: Educational documentation explaining the tools and architecture used in this project.

## Stacks

The infrastructure is broken down into modular stacks, all utilizing rootless Podman where possible:

- **Management & Observability:** Homepage, Dockge
- **Security Operations Center (SOC):** Wazuh, Falco, DefectDojo, **RamaLama (AI Analysis)**
- **Core Security Infrastructure:** Vaultwarden (Secrets), Kanidm (Identity), Step-CA (Internal PKI), Harbor (Registry), CrowdSec (Intrusion Prevention)

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

### 1. Node Initialization

Run the initialization script on your target openSUSE MicroOS machine. This configures the `podman.socket`, sets up rootless sub-U/G IDs, and ensures security compliance (e.g., `auditd`).

```bash
sudo ./init-node.sh
```

### 2. Deploy a Stack

The `deploy.sh` wrapper simplifies deploying and managing individual stacks. It automatically sources the global `.env` file and executes the corresponding `podman-compose` command.

**Usage:**
```bash
./deploy.sh [stack-name] [command]
```

**Examples:**
```bash
# Bring up the 'homepage' stack in the background
./deploy.sh homepage up

# View logs for 'vaultwarden'
./deploy.sh vaultwarden logs

# Tear down the 'dockge' stack
./deploy.sh dockge down
```

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
