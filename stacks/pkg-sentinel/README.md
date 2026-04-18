# pkg-sentinel — Developer Setup Guide

**Supply-Chain Security Proxy** for Geo-Brain

pkg-sentinel is an optional developer stack that intercepts package downloads
from npm, PyPI, and Maven registries. Each package is detonated inside an
ephemeral, rootless Podman sandbox while [Azazel](https://github.com/topics/ebpf)
eBPF tracing monitors for information exfiltration. Safe packages are served
(HTTP 200); malicious packages are blocked (HTTP 403).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Architecture Overview](#architecture-overview)
3. [Deployment](#deployment)
4. [Developer Environment Setup](#developer-environment-setup)
5. [Configuring Package Managers](#configuring-package-managers)
6. [Configuration Reference](#configuration-reference)
7. [Exfiltration Detection Rules](#exfiltration-detection-rules)
8. [LLM Integration (Optional)](#llm-integration-optional)
9. [Building from Source](#building-from-source)
10. [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement         | Minimum Version | Notes                                      |
|---------------------|-----------------|---------------------------------------------|
| **Podman**          | 4.9+            | Rootless mode with `podman.socket` enabled  |
| **Go**              | 1.21+           | Only needed for local development builds    |
| **Azazel eBPF**     | —               | Must be installed on the host               |
| **Kernel**          | 5.8+            | Required for BPF ring buffer support        |
| **Host Caps**       | —               | `CAP_BPF`, `CAP_SYS_ADMIN`, `CAP_PERFMON`  |
| **Geo-Brain Stack** | —               | Step-CA + Traefik deployed and healthy      |

> **Note:** pkg-sentinel requires elevated capabilities for eBPF tracing.
> The container is labeled `security.stig.bypass_privileged=true` per
> GEMINI.md policy. The sandbox containers themselves are fully rootless
> and network-isolated.
>
> **Azazel Installation:** The Azazel eBPF binary must be available inside
> the container at the path configured by `PKG_SENTINEL_AZAZEL_BIN`
> (default: `/usr/local/bin/azazel`). Either install it during the
> container image build (add to the Containerfile) or bind-mount it from
> the host by adding a volume to `docker-compose.yml`:
> ```yaml
> volumes:
>   - /usr/local/bin/azazel:/usr/local/bin/azazel:ro
> ```

---

## Architecture Overview

```
Developer / CI                 pkg-sentinel                    Upstream Registry
  │                              │                                │
  │  GET /npm/lodash/-/4.17.tgz │                                │
  ├─────────────────────────────►│                                │
  │                              │  1. Fetch package to RAM disk  │
  │                              ├───────────────────────────────►│
  │                              │◄───────────────────────────────┤
  │                              │                                │
  │                              │  2. Spin up Podman sandbox     │
  │                              │     (netns=none, rootless)     │
  │                              │                                │
  │                              │  3. Attach Azazel eBPF tracer  │
  │                              │     (syscall monitoring)       │
  │                              │                                │
  │                              │  4. Evaluate NDJSON telemetry  │
  │                              │     against 4 exfil rules      │
  │                              │                                │
  │         HTTP 200 (safe)      │  5. Optional: LLM analysis     │
  │◄─────────────────────────────┤     via RamaLama               │
  │   or HTTP 403 (blocked)      │                                │
  │                              │  6. Teardown sandbox + cleanup │
```

### Network Topology

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  proxy-net  │────►│  pkg-sentinel    │────►│ secure-      │
│ (external)  │     │  container       │     │ backbone     │
│             │     │                  │     │ (RamaLama)   │
└─────────────┘     │                  │     └──────────────┘
                    │                  │
                    │                  │────►┌──────────────┐
                    │                  │     │ sandbox-net  │
                    └──────────────────┘     │ (internal)   │
                                            └──────────────┘
```

---

## Deployment

### Quick Start (Recommended)

```bash
# From the Geo-Brain repository root:

# 1. Ensure base infrastructure is running
./deploy.sh base up

# 2. Deploy the developer stack
./deploy.sh dev up

# Or deploy pkg-sentinel standalone:
./deploy.sh pkg-sentinel up
```

### First-Time Setup

1. **Copy environment variables** — Add pkg-sentinel variables to your `.env`:

   ```bash
   # Optional: Override defaults (see Configuration Reference below)
   PKG_SENTINEL_TIMEOUT=15s
   PKG_SENTINEL_DEFAULT_ACTION=block
   PKG_SENTINEL_SANDBOX_IMAGE=docker.io/library/node:20-alpine
   ```

2. **Verify Azazel is installed** on the host:

   ```bash
   which azazel
   azazel --version
   ```

3. **Verify kernel capabilities**:

   ```bash
   # Check BPF support
   zcat /proc/config.gz | grep CONFIG_BPF
   # Expected: CONFIG_BPF=y, CONFIG_BPF_SYSCALL=y

   # Check current capabilities
   capsh --print | grep -i bpf
   ```

4. **Deploy**:

   ```bash
   ./deploy.sh pkg-sentinel up
   ```

5. **Verify health**:

   ```bash
   curl -sk https://pkg-sentinel.${DOMAIN}/healthz
   # {"status":"ok"}
   ```

---

## Developer Environment Setup

### Local Development (Without Containers)

For active development on the pkg-sentinel codebase:

```bash
cd stacks/pkg-sentinel/src

# Install Go dependencies
go mod tidy

# Run locally (requires Podman socket and Azazel)
export PKG_SENTINEL_LISTEN=:8443
export PKG_SENTINEL_PODMAN_SOCK=/run/user/$(id -u)/podman/podman.sock
export PKG_SENTINEL_TIMEOUT=15s
export PKG_SENTINEL_DEFAULT_ACTION=block

go run .
```

### Running Tests

```bash
cd stacks/pkg-sentinel/src

# Unit tests
go test ./...

# Unit tests with race detector
go test -race ./...

# Test the rule engine specifically
go test -v ./rules/...
```

### Building the Container Image

```bash
cd stacks/pkg-sentinel

# Build with Podman
podman build -t localhost/pkg-sentinel:dev -f Containerfile .

# Test the built image
podman run --rm -p 8443:8443 localhost/pkg-sentinel:dev
```

---

## Configuring Package Managers

After deploying pkg-sentinel, configure your local package managers to route
through the proxy.

### npm

```bash
# Set the registry to the pkg-sentinel npm endpoint
npm config set registry https://pkg-sentinel.${DOMAIN}/npm/

# Or per-project in .npmrc:
echo "registry=https://pkg-sentinel.${DOMAIN}/npm/" > .npmrc
```

### pip (PyPI)

```bash
# Global configuration
pip config set global.index-url https://pkg-sentinel.${DOMAIN}/pypi/simple/

# Or per-invocation:
pip install --index-url https://pkg-sentinel.${DOMAIN}/pypi/simple/ <package>
```

### Maven

Add to your `~/.m2/settings.xml`:

```xml
<settings>
  <mirrors>
    <mirror>
      <id>pkg-sentinel</id>
      <mirrorOf>central</mirrorOf>
      <url>https://pkg-sentinel.${DOMAIN}/maven/</url>
    </mirror>
  </mirrors>
</settings>
```

### CI/CD Integration

In your Gitea Actions workflows:

```yaml
env:
  NPM_CONFIG_REGISTRY: https://pkg-sentinel.${{ vars.DOMAIN }}/npm/
  PIP_INDEX_URL: https://pkg-sentinel.${{ vars.DOMAIN }}/pypi/simple/
```

---

## Configuration Reference

All configuration is via environment variables set in the root `.env` file
or directly in the `docker-compose.yml`.

| Variable                           | Default                              | Description                                               |
|------------------------------------|--------------------------------------|-----------------------------------------------------------|
| `PKG_SENTINEL_LISTEN`              | `:8443`                              | Address and port the proxy listens on                     |
| `PKG_SENTINEL_TIMEOUT`             | `15s`                                | Max detonation time before applying default action        |
| `PKG_SENTINEL_DEFAULT_ACTION`      | `block`                              | Action on timeout: `block` (403) or `allow` (200)         |
| `PKG_SENTINEL_AZAZEL_BIN`          | `/usr/local/bin/azazel`              | Path to the Azazel eBPF tracer binary                     |
| `PKG_SENTINEL_PODMAN_SOCK`         | `/run/podman/podman.sock`            | Path to the Podman API socket (inside the container)      |
| `PKG_SENTINEL_SANDBOX_IMAGE`       | `docker.io/library/node:20-alpine`   | OCI image for sandbox containers                          |
| `PKG_SENTINEL_LLM_ENDPOINT`        | *(empty)*                            | Optional RamaLama endpoint for AI analysis                |
| `PKG_SENTINEL_RAMDISK`             | `/dev/shm/pkg-sentinel`              | RAM disk path for temporary package cache                 |
| `PKG_SENTINEL_NPM_UPSTREAM`        | `https://registry.npmjs.org`         | Upstream npm registry URL                                 |
| `PKG_SENTINEL_PYPI_UPSTREAM`       | `https://pypi.org`                   | Upstream PyPI registry URL                                |
| `PKG_SENTINEL_MAVEN_UPSTREAM`      | `https://repo1.maven.org/maven2`     | Upstream Maven Central URL                                |

---

## Exfiltration Detection Rules

The rule engine evaluates Azazel eBPF telemetry (NDJSON events) in real-time.
Each event is checked against four rules in order; the first violation blocks
the package.

| Rule ID    | Name                           | What It Detects                                                  |
|------------|--------------------------------|-------------------------------------------------------------------|
| `EXFIL-001`| Sensitive File Reads           | `open`/`openat`/`read` on `~/.ssh/*`, `/etc/shadow`, `.env`, `.aws/credentials`, `.npmrc`, `.kube/config`, etc. |
| `EXFIL-002`| Anomalous Network Egress       | `connect` to non-registry IPs, `SOCK_RAW` creation, DNS to suspicious domains (ngrok, requestbin, etc.) |
| `EXFIL-003`| Exfiltration via Execution     | `execve` of `curl`, `wget`, `nc`, `socat`; obfuscated `base64 \| sh` patterns |
| `EXFIL-004`| Environment Variable Harvesting| Access to `AWS_ACCESS_KEY_ID`, `GITHUB_TOKEN`, etc.; reads of `/proc/*/environ` |

### Adding Custom Rules

The rule engine is a Go interface in `src/rules/exfiltration.go`. To add a
new rule:

1. Add a new method `rule<Name>(ev TelemetryEvent) Verdict` to the `Engine` struct.
2. Call it from `Engine.Evaluate()` in the desired priority order.
3. Rebuild the container image.

---

## LLM Integration (Optional)

When `PKG_SENTINEL_LLM_ENDPOINT` is set, the analyzer sends the full event
stream to a local AI inference endpoint (e.g., RamaLama) after the rule
engine passes. The LLM performs deeper behavioral analysis on the telemetry.

```bash
# In your .env, point to the RamaLama instance:
PKG_SENTINEL_LLM_ENDPOINT=http://ramalama:8080/v1/chat/completions
```

The LLM is expected to return:
```json
{
  "suspicious": false,
  "confidence": 0.95,
  "summary": "Normal package installation behavior observed."
}
```

> **Note:** LLM analysis is non-blocking. If the LLM endpoint is unreachable,
> the proxy falls back to rule-engine-only evaluation.

---

## Building from Source

### Prerequisites

```bash
# Install Go 1.21+
go version

# Ensure Podman is available
podman version
```

### Build & Run

```bash
cd stacks/pkg-sentinel/src

# Download dependencies
go mod tidy

# Build
go build -o pkg-sentinel .

# Run
./pkg-sentinel
```

### Project Structure

```
stacks/pkg-sentinel/
├── Containerfile              # Multi-stage build (Go → Alpine)
├── docker-compose.yml         # STIG-compliant compose definition
├── README.md                  # This file
└── src/
    ├── go.mod                 # Go module definition
    ├── main.go                # Core proxy server + route multiplexing
    ├── analyzer/
    │   └── azazel.go          # Azazel eBPF tracer + NDJSON stream parser
    ├── config/
    │   └── config.go          # Environment-driven configuration
    ├── orchestrator/
    │   └── podman.go          # Podman container lifecycle management
    └── rules/
        └── exfiltration.go    # 4-rule exfiltration detection engine
```

---

## Troubleshooting

### Common Issues

**"azazel: command not found"**
Azazel must be installed on the host or mounted into the container. Ensure
the binary path matches `PKG_SENTINEL_AZAZEL_BIN`.

**"permission denied" on Podman socket**
Verify the socket is mounted read-only and accessible:
```bash
ls -la ${PODMAN_SOCK}
podman info  # Should work without sudo
```

**Sandbox containers fail to start**
Check that the sandbox image is pulled and available:
```bash
podman pull docker.io/library/node:20-alpine
```

**Detonation always times out**
Increase `PKG_SENTINEL_TIMEOUT` or check Azazel output for errors:
```bash
podman logs pkg-sentinel 2>&1 | grep -i "azazel"
```

**Connection refused on port 8443**
Verify Traefik routing is configured (deploy.sh generates this automatically):
```bash
curl -sk https://pkg-sentinel.${DOMAIN}/healthz
```

### Viewing Logs

```bash
# Via deploy.sh
./deploy.sh pkg-sentinel logs

# Direct
podman logs -f pkg-sentinel

# Persistent logs on disk
tail -f ${DATA_DIR}/pkg-sentinel/logs/*.log
```

---

## Security Considerations

- **Privilege Separation:** The proxy requires `CAP_BPF`, `CAP_SYS_ADMIN`,
  and `CAP_PERFMON` for eBPF tracing. Sandbox containers run with **no
  capabilities** (`cap_drop: ALL`) and **no network** (`netns=none`).

- **RAM Disk Cleanup:** Package payloads are cached in `/dev/shm` only during
  detonation and immediately cleaned up after serving or blocking.

- **STIG Compliance:** The container is labeled per GEMINI.md mandates with
  explicit `security.stig.bypass_privileged=true` for the eBPF capabilities.

- **Air-Gap Compatibility:** When deployed with Quay as a pull-through cache,
  no direct internet access is required. Configure upstream registry URLs to
  point to the local Quay mirror.
