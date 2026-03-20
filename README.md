<p align="center">
  <img src="./docs/logo.svg" alt="admin-Brain SSOF Logo" width="128"/>
</p>

# admin-Brain SSOF: Single Node Homelab

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
- **TLS certificates** generated or provided before deployment — see **[certs/README.md](./certs/README.md)** for instructions.
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
./init-node.sh --host 10.0.0.5 --user admin --key ~/.ssh/id_ed25519

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

## Post-Deployment: Service URLs

After a successful `./deploy.sh all up`, the following web interfaces are available. Replace `${DOMAIN}` with your configured domain (default: `brain.lan`).

### Via Traefik (HTTPS Reverse Proxy)

These services are routed through Traefik and accessible by hostname. Requires DNS or `/etc/hosts` entries pointing `*.${DOMAIN}` to the homelab node IP.

| Service | URL | Purpose |
|---------|-----|---------|
| **Homepage** | `https://home.${DOMAIN}` | Centralized dashboard |
| **Traefik** | `https://traefik.${DOMAIN}` | Reverse proxy dashboard |
| **Authelia** | `https://auth.${DOMAIN}` | SSO / 2FA portal |
| **Grafana** | `https://grafana.${DOMAIN}` | Metrics & log visualization |
| **Wazuh** | `https://wazuh.${DOMAIN}` | SIEM / XDR dashboard |
| **DefectDojo** | `https://defectdojo.${DOMAIN}` | Vulnerability management |
| **Harbor** | `https://harbor.${DOMAIN}` | Container registry |
| **Kanidm** | `https://kanidm.${DOMAIN}` | Identity management |
| **MinIO** | `https://minio.${DOMAIN}` | S3 object storage console |
| **Dockge** | `https://dockge.${DOMAIN}` | Stack management UI |
| **Step-CA** | `https://ca.${DOMAIN}` | Internal PKI / CA |
| **SilverBullet** | `https://silverbullet.${DOMAIN}` | Note-taking (user stack) |
| **Moodle** | `https://moodle.${DOMAIN}` | LMS (user stack) |

### Direct Access (by Port)

These services are reachable directly on the node IP without Traefik. Useful for initial setup or when DNS is not yet configured.

| Service | URL | Purpose |
|---------|-----|---------|
| **Homepage** | `http://<NODE_IP>:3000` | Dashboard |
| **Grafana** | `http://<NODE_IP>:3001` | Metrics UI |
| **Dockge** | `http://<NODE_IP>:5001` | Stack manager |
| **Wazuh Dashboard** | `http://<NODE_IP>:5601` | SIEM UI |
| **CrowdSec LAPI** | `http://<NODE_IP>:8180` | Bouncer API |
| **RamaLama** | `http://<NODE_IP>:8084` | LLM inference API |
| **Kanidm** | `https://<NODE_IP>:8443` | IDM (native TLS) |
| **MinIO API** | `http://<NODE_IP>:9000` | S3 API endpoint |
| **MinIO Console** | `http://<NODE_IP>:9001` | MinIO web UI |
| **Authelia** | `http://<NODE_IP>:9091` | Auth portal |
| **Prometheus** | `http://<NODE_IP>:9092` | Metrics query UI |
| **Step-CA** | `https://<NODE_IP>:9443` | CA API (native TLS) |
| **SilverBullet** | `http://<NODE_IP>:3002` | Notes (user stack) |
| **Loki** | `http://<NODE_IP>:3100` | Log push/query API |

---

## Setup Requirements Beyond `.env`

Modifying `.env` is necessary but not sufficient. The following steps must be completed before or during first deployment.

### 1. TLS Certificates (Required Before First Deploy)

Traefik and Kanidm **will not start** without TLS certificates. Generate or provide them before running `deploy.sh`:

```bash
# Option A: Generate self-signed certs for the homelab
./scripts/gen-selfsigned-certs.sh

# Option B: Generate, deploy to remote, and trust on both hosts
./scripts/gen-selfsigned-certs.sh --all
```

See [certs/README.md](certs/README.md) for full details and manual certificate placement.

### 2. DNS or `/etc/hosts` Configuration

For Traefik hostname routing to work, the node must be resolvable. Use wildcard domains, or add entries to `/etc/hosts` on every client machine:

### 3. Trust the CA Certificate (If Self-Signed)

Browsers will reject self-signed certificates until the CA is trusted. After generating certs:

```bash
# Fedora / RHEL
sudo cp certs/ca.crt /etc/pki/ca-trust/source/anchors/Geo-Brain-ca.crt
sudo update-ca-trust

# Debian / Ubuntu
sudo cp certs/ca.crt /usr/local/share/ca-certificates/Geo-Brain-ca.crt
sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/ca.crt
```

Import `certs/ca.crt` into your browser's certificate store if it doesn't honor the system trust store.

### 4. CrowdSec Bouncer Key

The CrowdSec–Traefik integration requires a bouncer API key generated from the running CrowdSec container:

```bash
# After CrowdSec is up:
./deploy.sh crowdsec up

# SSH into the node and generate the key:
ssh admin@<NODE_IP> 'podman exec crowdsec cscli bouncers add traefik-bouncer -o raw'

# Paste the output into .env as CROWDSEC_BOUNCER_API_KEY, then redeploy Traefik:
./deploy.sh traefik up
```

### 5. Kanidm Initial Admin Setup

Kanidm requires bootstrapping the admin account after first start:

```bash
# After Kanidm is running:
ssh admin@<NODE_IP> 'podman exec kanidm kanidmd recover-account -c /data/server.toml idm_admin'
```

This prints a one-time password for the `idm_admin` account. Log in at `https://kanidm.${DOMAIN}`.
To enable the rest of the proxy infrastructure, you must immediately create the Authelia service account:
1. Navigate to **Persons** and create a new user named `authelia_svc`.
2. Set its password to the `AUTHELIA_LDAP_PASSWORD` defined in your `.env` file.
3. Authelia will automatically connect and Traefik will begin routing traffic to the dashboards.

### 6. Harbor Admin Login

Harbor's admin password is set via `HARBOR_ADMIN_PASSWORD` in `.env`. After first deploy, log in at `https://harbor.${DOMAIN}` with username `admin` and the configured password to set up projects and robot accounts.

### 7. Wazuh Initial Credentials

Wazuh Dashboard default credentials are `admin` / `admin`. Change them immediately after first login at `https://wazuh.${DOMAIN}` (port 5601).

### 8. DefectDojo First Login

DefectDojo creates a default admin user on first run. Check the container logs for the auto-generated password:

```bash
ssh admin@<NODE_IP> 'podman logs defectdojo-django 2>&1 | grep -i "admin password"'
```

### 9. Data Directory Permissions

Ensure the persistent data directory exists and is owned by the Podman user on the remote node:

```bash
ssh admin@<NODE_IP> 'sudo mkdir -p /var/Geo-Brain && sudo chown 1000:1000 /var/Geo-Brain'
```

`init-node.sh` handles this automatically, but verify if provisioning was done manually.

---

## Deploying User Stacks

To keep your personal, uncommitted stacks separate from the core infrastructure, place them inside the `stacks/user/` directory (which is ignored by Git).

1. Create a directory for your stack: `mkdir -p stacks/user/mystack`
2. Create your `docker-compose.yml` inside it.
3. Deploy it using the `deploy.sh` script by prefixing the target with `user/`:

```bash
./deploy.sh user/mystack up
```

Alternatively, you can redeploy all user stacks at once:

```bash
./deploy.sh user up
```

## STIG & Security Validation

The deployment wrapper (`deploy.sh`) automatically enforces STIG compliance checks before deploying any stack. It verifies image pinning, rootless execution, read-only filesystems, capability drops, health checks, and strict resource limits.

You can run these validations manually without deploying to ensure your custom stacks meet the baseline requirements:

```bash
# Validate a specific stack
./deploy.sh harbor check

# Validate a user stack
./deploy.sh user/mystack check
```

---

**Note:** Ensure all data persistence directories (`./data`) have appropriate permissions (e.g., `1000:1000`) to match the user namespace mapping within the rootless Podman containers.
