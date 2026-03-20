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

- **Core Infrastructure:** `step-ca` (Internal PKI), `harbor` (Container Registry), `traefik` (Reverse Proxy)
- **Identity & Access:** `kanidm` (Identity Provider), `authelia` (SSO/MFA)
- **Security Operations:** `wazuh` (SIEM), `falco` (Runtime Security), `crowdsec` (IPS)
- **Observability:** `prometheus` & `grafana` (Metrics), `vector` & `loki` (Logs)
- **Management:** `homepage` (Dashboard), `dockge` (Stack UI)

All traffic is encrypted, and user access is governed by strict SSO (Single Sign-On).

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

Generate the root CA and required SSL certificates for `step-ca`, `harbor`, and `kanidm`:

```bash
./scripts/gen-selfsigned-certs.sh
```

### Step 4: Deploy the Infrastructure

Deploy all stacks. The script automatically handles bootstrapping Harbor and Step-CA before rolling out the remaining services:

```bash
./deploy.sh all up
```

### Step 5: Post-Deployment Setup

Run the setup script to initialize identities, integrate Step-CA with Traefik via ACME, and configure rootless service accounts:

```bash
./setup-geo-brain.sh
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
*(You can also use `./scripts/gen-selfsigned-certs.sh --trust-local` to automate this).*

### Step 7: Initial Logins

- **Homepage (Dashboard):** `https://home.<DOMAIN>` - Your central access point.
- **Kanidm (Identity):** `https://kanidm.<DOMAIN>` - Initial login uses the `idm_admin` account. The setup script configures it automatically with the `ADMIN_PASSWORD` defined in `.env`.
- **Harbor (Registry):** `https://harbor.<DOMAIN>` - Log in with `admin` and the `HARBOR_ADMIN_PASSWORD` from `.env`.
- **Dockge (Stack Management):** `https://dockge.<DOMAIN>` - Visual management for all your Podman Compose stacks.

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
