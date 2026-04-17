#!/bin/bash
DOMAIN="brain.home.lan"
HOSTS=("ca" "kanidm" "auth" "minio" "quay" "grafana" "wazuh" "defectdojo" "dockge" "traefik" "gitea" "prometheus" "moodle" "n8n" "notes" "brain.home.lan")

for host in "${HOSTS[@]}"; do
    if [[ "$host" == "brain.home.lan" ]]; then
        url="http://$host"
    else
        url="http://$host.$DOMAIN"
    fi
    echo -n "Testing $url ... "
    # We use -I to get headers. We don't resolve to remote node automatically without --resolve or ssh.
    # It's better to execute this ON the remote node so DNS resolves, or use curl --resolve
    # Let's just ssh and run it.
done
