# Gitea & CI/CD Pipeline

**Git Server & DevSecOps Platform** for My-HomeLab

The `gitea` stack provides a fully self-hosted Git server, integrated with CI/CD runners, AI-driven log triage, and vulnerability management. This forms the backbone of the "Two-Way Mirror" workflow required by the My-HomeLab architectural mandates.

---

## Architecture Overview

When deployed via `./deploy.sh cicd up`, this stack provisions:

1. **Gitea:** The primary Git server and UI.
2. **Ephemeral Runners:** Sandboxed CI/CD runners that use Podman/Kata for secure Docker-in-Docker execution.
3. **DefectDojo:** The centralized vulnerability management and orchestration platform.
4. **RamaLama:** Air-gapped AI used for automated code review and condensing DefectDojo security logs.

These components share the `vulnerability-net` to ensure isolated, air-gapped processing of source code and security vulnerabilities.

---

## Bidirectional Git Mirroring

A core feature of the CI/CD platform is **Bidirectional Git Mirroring** to ensure that all code pushed to the internal homelab is heavily vetted before synchronizing with external platforms like GitHub.com.

### How It Works

1. **Push:** Developers push their personal work or application code directly to the internal Gitea server (`https://gitea.example.local`).
2. **Scan:** The push triggers a Gitea Action. The CI pipeline spins up an ephemeral, kernel-sandboxed runner. This runner performs SAST, DAST, and dependency scanning.
3. **Report:** Scan results are uploaded directly to the internal DefectDojo instance over `vulnerability-net`.
4. **Triage:** RamaLama parses the scan logs from DefectDojo and generates an actionable summary for the developer, leaving a comment on the Pull Request.
5. **Approval:** DefectDojo acts as the quality gate. If the vulnerability threshold is acceptable, the Pull Request can be merged into the `main` branch.
6. **Mirror:** Once merged to `main`, a post-merge hook or action automatically pushes the clean, verified commit to the designated upstream repository on GitHub.com.

### Setup Instructions

To enable the Two-Way Mirror for a repository:

1. Create the repository in your internal Gitea instance.
2. Go to **Settings > Repository Settings > Mirror Settings**.
3. Configure the upstream URL (e.g., `https://github.com/your-username/repo.git`).
4. Provide the necessary Personal Access Token (PAT) for GitHub authentication.
5. Check the "Push Mirror" option so that internal changes synchronize to GitHub. *Ensure you configure the mirror to only sync specific branches (e.g., `main`) after your CI/CD pipelines have run.*

## Routine Repository Scanning

In addition to ephemeral run-time scans, a **Scheduled Routine Runner** continuously scans all mirrored repositories. 

- The runner pulls down repositories nightly.
- Executes `trivy` or `grype` to detect newly disclosed vulnerabilities (CVEs) or configuration drift in Infrastructure as Code (IaC).
- Alerts are sent to Wazuh / DefectDojo.

## Logging and Observability

All CI/CD logs, runner execution data, and AI interactions are automatically routed via **Vector** to **Loki** and **Wazuh**:
- Access Grafana (`https://grafana.example.local`) to query historical runner logs and performance metrics.
- Wazuh Manager receives structured security alerts whenever a CI action detects a policy violation or attempts unexpected network egress during the sandboxed build process.
