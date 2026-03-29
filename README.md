<p align="center">
  <img src="./docs/logo.svg" alt="Geo-Brain SSOF Logo" width="128"/>
</p>

# Geo-Brain: Single Node Homelab

Welcome to the **Geo-Brain** Single Source of Truth (SSOT) repository. This project deploys a highly secure, STIG-compliant, and fully containerized homelab on a single node using rootless **Podman** and **Docker Compose**.

> **Note:** This is not a CI/CD pipeline. It focuses on operational security, monitoring, and robust zero-trust access for pre-built containers.

For a detailed breakdown of every tool and architectural choice, see **[TOOLS_EXPLAINED.md](./docs/TOOLS_EXPLAINED.md)**. For the overarching security philosophy and architectural mandates, see **[GEMINI.md](./GEMINI.md)**.

---

## 📖 Overview

The Geo-Brain homelab is organized into discrete **stacks**:

- **Core Infrastructure:** `step-ca` (Internal PKI), `quay` (Container Registry), `traefik` (Reverse Proxy)
- **Identity & Access:** `kanidm` (Identity Provider), `authelia` (SSO/MFA)
- **Security Operations:** `wazuh` (SIEM), `falco` (Runtime Security), `crowdsec` (IPS)
- **Observability:** `prometheus` & `grafana` (Metrics), `vector` & `loki` (Logs)
- **Management:** `homepage` (Dashboard), `dockge` (Stack UI)

---

## 🚀 Quick Start Guide

Follow these steps to deploy Geo-Brain from scratch on a remote node (e.g., `brain.home.lan`).

### Step 1: Environment Configuration

Copy the template and set your domain and secrets:

```bash
cp .env-template .env
```
Edit `.env` to configure your target `DOMAIN` (default: `brain.home.lan`), connection settings (`REMOTE_HOST`, `REMOTE_USER`), and critical passwords. **Do not commit your `.env` file.**

### Step 2: Initialize the Node

Run the node initialization script to install dependencies (Podman, Ansible), configure SELinux/firewalld, set up Podman networks, and create the required data directories:

```bash
./init-node.sh
```

### Step 3: Generate Certificates

Generate the root CA and required SSL certificates for `step-ca`, `quay`, and `kanidm`:

```bash
./scripts/secrets/gen-selfsigned-certs.sh
```

### Step 4: Deploy the Infrastructure

Deploy all stacks. The script automatically handles bootstrapping Quay and Step-CA before rolling out the remaining services:

```bash
./deploy.sh all up
```

### Step 5: Post-Deployment Setup

Run the setup script to initialize identities, integrate Step-CA with Traefik via ACME, and configure rootless service accounts:

```bash
./setup-brain.sh
```

### Step 6: Trust the Root Certificate

To avoid browser warnings, install the generated Root CA onto your local workstation:

- **Fedora/RHEL/openSUSE:** 
  ```bash
  sudo cp certs/ca.crt /etc/pki/ca-trust/source/anchors/Geo-Brain-ca.crt && sudo update-ca-trust
  ```
- **macOS:**
  ```bash
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/ca.crt
  ```
*(You can also use `./scripts/secrets/gen-selfsigned-certs.sh --trust-local` to automate this).*

### Step 7: Initial Logins & User Setup

Your central access point for all services is the **Homepage (Dashboard):** `https://home.<DOMAIN>`

Before logging into downstream apps, you **must** bootstrap your identity provider:

1. **Kanidm (Identity):** `https://kanidm.<DOMAIN>`
   - First, run the manual bootstrap command shown at the end of the setup script to recover the `idm_admin` account.
   - Log in using the recovery password, then navigate to **Persons** and set a permanent password.
   - Create a service account named `authelia_svc` (used by Authelia for SSO/MFA). Set its password to the `AUTHELIA_LDAP_PASSWORD` defined in your `.env`.
   - **OIDC Configuration:** The following stacks are **already pre-configured** to use OIDC. You only need to create the corresponding **OIDC Clients** in Kanidm using the values from the `setup-brain.sh` summary:
     - **Quay** (Redirect: `https://quay.<DOMAIN>/oauth2/oidc/callback`)
     - **DefectDojo** (Redirect: `https://defectdojo.<DOMAIN>/complete/oidc/`)
     - **MinIO** (Redirect: `https://minio.<DOMAIN>/oauth_callback`)
     - **Wazuh** (Redirect: `https://wazuh.<DOMAIN>/api/v1/auth/login`)


2. **Quay (Registry):** `https://quay.<DOMAIN>`
   - **SSO:** Already configured declaratively. Simply click 'OIDC' on the login screen once the Kanidm client is created.
   - **Local Admin:** Use for break-glass only. Set up during first visit if OIDC is not yet active.

3. **Wazuh (SIEM):** `https://wazuh.<DOMAIN>`
   - **SSO:** Already configured declaratively. Uses `Preferred_Username` claim from Kanidm.
   - **Local Admin:** Default credentials are `admin` / `admin`. Change this immediately.

4. **DefectDojo (Vulnerability Management):** `https://defectdojo.<DOMAIN>`
   - **SSO:** Already configured declaratively. Click "Log in via Kanidm SSO."
   - **Local Admin:** Extract randomly generated password from initializer logs:
     `podman logs defectdojo-initializer 2>&1 | grep "Admin password:"`

5. **MinIO (Object Storage):** `https://minio.<DOMAIN>`
   - **SSO:** Already configured declaratively. Click "Login with OpenID."
   - **Local Admin:** Uses `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` from your `.env`.

7. **Grafana (Observability):** `https://grafana.<DOMAIN>`
   - **SSO:** Automatic via Authelia ForwardAuth headers. No manual setup required.

8. **Dockge (Stack Management):** `https://dockge.<DOMAIN>`
   - First-time access will prompt you to create the local admin account.
   - Use Dockge to visually manage, start, stop, and read logs of all your deployed Compose stacks.

---

## 🧹 Maintenance & Teardown

If you need to completely wipe the installation (destroy all data, volumes, and containers) and start fresh:

```bash
./scripts/clean-node.sh
```
*Warning: This script permanently deletes `/var/Geo-Brain` and all rootless podman data on the remote node.*

---

## ⚙️ How to Deploy Individual Stacks

The `deploy.sh` script dynamically generates Traefik configurations and manages stack lifecycles over SSH using `podman-compose`.

```bash
# Bring up a specific stack
./deploy.sh <stack_name> up

# Tear down a stack
./deploy.sh <stack_name> down

# View logs for a stack
./deploy.sh <stack_name> logs

# Validate STIG compliance of a stack without deploying
./deploy.sh <stack_name> check
```

---

## 👤 Adding User Applications

You can deploy your own uncommitted applications via the `user/` directory.

1. Create a folder: `mkdir -p stacks/user/myapp`
2. Add your `docker-compose.yml`.
3. Deploy it: `./deploy.sh user/myapp up`

All user stacks automatically receive Traefik reverse proxy configuration if they include the label `traefik.enable=true`.
