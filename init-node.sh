#!/usr/bin/env bash
# init-node.sh: Initialize an openSUSE MicroOS node for remote Podman deployments.
# Usage: ./init-node.sh (Run on the target node)

set -e

# Identification
OS_ID=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
USER=$(whoami)
UID_VAL=$(id -u)

echo ">>> Initializing node for brain-ssof (STIG Homelab)..."

# 1. OS Validation
if [[ "$OS_ID" == "opensuse-microos" ]]; then
    PKG_MGR="transactional-update pkg install"
    REBOOT_CMD="sudo reboot"
elif [[ "$OS_ID" == "fedora" || "$OS_ID" == "coreos" ]]; then
    echo ">>> Detected Fedora/CoreOS system..."
    PKG_MGR="rpm-ostree install"
    REBOOT_CMD="sudo systemctl reboot"
else
    echo "[WARNING] Unknown OS: $OS_ID. Manual package installation required."
    PKG_MGR="echo [MANUAL] Install:"
    REBOOT_CMD="reboot"
fi

# 2. Package Installation (Check and warn)
check_pkg() {
    if ! rpm -q "$1" &> /dev/null; then
        echo "[REQUIRED] Package '$1' is missing."
        echo "Run: sudo $PKG_MGR $1 && $REBOOT_CMD"
        return 1
    fi
    return 0
}

PACKAGES=("podman" "podman-compose" "audit" "openssh" "policycoreutils")
MISSING=0
for pkg in "${PACKAGES[@]}"; do
    check_pkg "$pkg" || MISSING=$((MISSING+1))
done

if [ $MISSING -gt 0 ]; then
    echo "[CRITICAL] $MISSING required packages are missing. Fix them before continuing."
    # We don't exit here because some might be in the current transaction but not yet rebooted
fi

# 3. Rootless Configuration (subuid/subgid)
if ! grep -q "$USER" /etc/subuid; then
    echo "[FIXING] Configuring subuids for $USER..."
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
fi

# 4. Podman Socket for Remote Access
echo ">>> Enabling podman.socket for rootless usage..."
systemctl --user enable --now podman.socket

# 5. Security Services (auditd)
if systemctl is-active --quiet auditd; then
    echo ">>> auditd is active."
else
    echo ">>> Starting auditd..."
    sudo systemctl enable --now auditd || echo "[ERROR] auditd failed to start."
fi

# 6. SELinux Check
if [[ $(getenforce) == "Enforcing" ]]; then
    echo ">>> SELinux is ENFORCING (Correct)."
else
    echo "[WARNING] SELinux is NOT Enforcing. Check /etc/selinux/config."
fi

# 7. Sysctl for rootless and high-load apps
if [[ $(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null) == "1" ]]; then
    echo ">>> kernel.unprivileged_userns_clone is enabled."
fi

# Wazuh/Indexer/Elasticsearch requirement
if [[ $(sysctl -n vm.max_map_count) -lt 262144 ]]; then
    echo "[FIXING] Setting vm.max_map_count=262144 for Wazuh..."
    sudo sysctl -w vm.max_map_count=262144
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.d/99-wazuh.conf
fi

# 8. Summary
echo ">>> node initialization complete."
echo ">>> Remote access URI: unix:///run/user/$UID_VAL/podman/podman.sock"
echo ">>> SSH Access: podman --remote --url ssh://$USER@$(hostname -f)/run/user/$UID_VAL/podman/podman.sock"
