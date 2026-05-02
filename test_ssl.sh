#!/bin/bash
DOMAIN="${DOMAIN:-example.local}"
HOSTS=("ca" "kanidm" "auth" "minio" "quay" "grafana" "wazuh" "defectdojo" "dockge" "traefik" "gitea" "prometheus" "moodle" "n8n" "notes" "pkg-sentinel" "$DOMAIN")

CA_CERT="stacks/traefik/config/certs/root_ca.crt"
if [[ ! -f "$CA_CERT" ]]; then
    echo "CA root not found at $CA_CERT"
    exit 1
fi

FAIL=0
for host in "${HOSTS[@]}"; do
    if [[ "$host" == "$DOMAIN" ]]; then
        url="$host"
    else
        url="$host.$DOMAIN"
    fi
    echo "--- Testing $url ---"
    
    # 1. Check Connectivity
    if ! curl --cacert "$CA_CERT" -s -L --max-time 10 "$url" >/dev/null 2>&1; then
        echo "  [FAIL] Connectivity failed"
        ((FAIL++))
        continue
    else
        echo "  [PASS] Connectivity OK"
    fi

    # 2. Check Issuer
    issuer=$(echo | openssl s_client -connect "$url":443 -servername "$url" 2>/dev/null | openssl x509 -noout -issuer | sed 's/issuer=//')
    if [[ "$issuer" != *"${DOMAIN} CA"* && "$issuer" != *"STIG-Homelab CA"* && "$issuer" != *"Omni-Shield CA"* ]]; then
        echo "  [FAIL] Invalid Issuer: $issuer"
        ((FAIL++))
    else
        echo "  [PASS] Issuer is correct"
    fi

    # 3. Check Expiration
    if ! echo | openssl s_client -connect "$url":443 -servername "$url" 2>/dev/null | openssl x509 -noout -checkend 2592000; then
        echo "  [FAIL] Certificate expires in less than 30 days"
        ((FAIL++))
    else
        echo "  [PASS] Certificate expiration is valid (> 30 days)"
    fi
done

exit $FAIL
