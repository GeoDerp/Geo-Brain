# TLS Certificates

This directory is **git-ignored**. Certificates must be generated locally.

## Prerequisites (Before `deploy.sh`)

TLS certificates **must exist** before running `deploy.sh` — Traefik and Kanidm will fail to start without them.

### Option A: Generate Self-Signed Certs (Recommended for Homelab)

```bash
# 1. Generate CA + wildcard + Kanidm certs (local only)
./scripts/secrets/gen-selfsigned-certs.sh

# 2. Generate, deploy to remote, and trust on both hosts
./scripts/secrets/gen-selfsigned-certs.sh --all
```

The script will:
1. Create a local CA (`ca.key` / `ca.crt`) valid for 10 years.
2. Issue a wildcard cert for `*.${DOMAIN}` (valid ~2.25 years).
3. Issue a Kanidm-specific cert with its SAN list.
4. Copy certs into `stacks/traefik/config/certs/` for Traefik.
5. Write `stacks/traefik/config/dynamic/tls.yml` automatically.
6. With `--deploy`: SCP Kanidm certs to `${DATA_DIR}/kanidm/certs/` on the remote host.
7. With `--trust-local` / `--trust-remote`: Install the CA into system trust stores.

### Option B: Provide Your Own Certs

Place the following files manually:

| File | Location |
|---|---|
| Wildcard cert | `stacks/traefik/config/certs/wildcard.crt` |
| Wildcard key | `stacks/traefik/config/certs/wildcard.key` |
| CA cert | `stacks/traefik/config/certs/ca.crt` |
| Kanidm chain cert | `${DATA_DIR}/kanidm/certs/kanidm-chain.crt` (on remote) |
| Kanidm key | `${DATA_DIR}/kanidm/certs/kanidm.key` (on remote) |

Then ensure `stacks/traefik/config/dynamic/tls.yml` references the correct paths inside the container (see existing template).

### Verification

```bash
# Confirm certs exist before deploying
ls -la certs/ca.crt certs/wildcard.crt certs/kanidm-chain.crt
ls -la stacks/traefik/config/certs/

# After deploy, verify from a client
curl -v https://home.example.local
openssl s_client -connect example.local:443 -servername home.example.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
```

## Quick Start

```bash
./scripts/secrets/gen-selfsigned-certs.sh          # generate only
./scripts/secrets/gen-selfsigned-certs.sh --all    # generate + deploy + trust
```

## Expected Files

After running `gen-selfsigned-certs.sh`, this directory contains:

| File | Purpose |
|---|---|
| `ca.key` | CA private key (4096-bit RSA) |
| `ca.crt` | CA certificate (10-year validity) |
| `ca.srl` | CA serial number tracker |
| `wildcard.key` | Wildcard leaf private key |
| `wildcard.crt` | Wildcard cert for `*.${DOMAIN}` |
| `wildcard.csr` | Wildcard CSR (intermediate artifact) |
| `san.cnf` | SAN config for wildcard cert |
| `kanidm.key` | Kanidm-specific private key |
| `kanidm.crt` | Kanidm cert for `kanidm.${DOMAIN}` |
| `kanidm-chain.crt` | Kanidm cert + CA chain bundle |
| `kanidm.csr` | Kanidm CSR (intermediate artifact) |
| `kanidm-san.cnf` | SAN config for Kanidm cert |

## Where Certs Are Deployed

| Destination | Files | Consumed By |
|---|---|---|
| `stacks/traefik/config/certs/` | `wildcard.crt`, `wildcard.key`, `ca.crt` | Traefik default TLS store |
| `${DATA_DIR}/kanidm/certs/` (remote) | `kanidm-chain.crt`, `kanidm.key` | Kanidm native HTTPS |

## SANs

**Wildcard cert:**
- `*.${DOMAIN}`, `${DOMAIN}`, `localhost`
- IP: `127.0.0.1`

**Kanidm cert:**
- `kanidm.${DOMAIN}`, `kanidm`, `localhost`
- IP: `127.0.0.1`
