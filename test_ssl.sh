#!/bin/bash
DOMAIN="brain.home.lan"
HOSTS=("ca" "kanidm" "auth" "minio" "quay" "grafana" "wazuh" "defectdojo" "dockge" "traefik" "gitea" "prometheus" "moodle" "n8n" "notes" "brain.home.lan" "pkg-sentinel")

CA_CERT="stacks/traefik/config/certs/ca-bundle.crt"
if [[ ! -f "$CA_CERT" ]]; then
    echo "CA bundle not found at $CA_CERT"
    exit 1
fi

for host in "${HOSTS[@]}"; do
    if [[ "$host" == "brain.home.lan" ]]; then
        url="https://$host"
    else
        url="https://$host.$DOMAIN"
    fi
    echo -n "Testing $url ... "
    
    if curl --cacert "$CA_CERT" -s -I "$url" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
    fi
done
