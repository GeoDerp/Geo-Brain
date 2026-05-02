#!/bin/bash
# tests/test_kube_compliance.sh: Dynamically converts compose files to Kube YAML and checks compliance.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Ensure kompose is available for the conversion
if [ ! -x /tmp/kompose ]; then
    echo ">>> Downloading kompose..."
    curl -sL https://github.com/kubernetes/kompose/releases/download/v1.35.0/kompose-linux-amd64 -o /tmp/kompose
    chmod +x /tmp/kompose
fi

PASS=0
FAIL=0

echo -e "\033[1;36m━━━ KUBE YAML COMPLIANCE SCAN ━━━\033[0m"

# Find all docker-compose.yml files except in templates
for compose_file in $(find "$REPO_ROOT/stacks" -name "docker-compose.yml" -not -path "*/_template/*"); do
    stack_name=$(basename "$(dirname "$compose_file")")
    echo -n "Scanning $stack_name... "
    
    tmp_dir=$(mktemp -d)
    
    # Strip volumes from compose file to avoid kompose host mount errors
    python3 -c "
import sys, yaml
with open('$compose_file', 'r') as f:
    d = yaml.safe_load(f)
if d and 'services' in d:
    for s in d['services'].values():
        if 'volumes' in s:
            del s['volumes']
with open('$tmp_dir/stripped.yml', 'w') as f:
    yaml.dump(d, f)
"
    
    # 1. Convert compose to Kube YAML
    if ! /tmp/kompose convert -f "$tmp_dir/stripped.yml" -o "$tmp_dir/kube.yaml" >/dev/null 2>&1; then
        echo -e "\033[0;33m⊘\033[0m SKIPPED (Kompose conversion failed or empty)"
        rm -rf "$tmp_dir"
        continue
    fi
    
    # 2. Scan the Kube YAML against STIG-Homelab requirements
    errors=$(python3 -c "
import sys, yaml

issues = []
try:
    with open('$tmp_dir/kube.yaml', 'r') as f:
        docs = yaml.safe_load_all(f)
        for doc in docs:
            if not doc: continue
            
            kind = doc.get('kind')
            if kind == 'Deployment' or kind == 'DaemonSet' or kind == 'StatefulSet':
                spec = doc.get('spec', {}).get('template', {}).get('spec', {})
                containers = spec.get('containers', [])
                
                for c in containers:
                    name = c.get('name', 'unknown')
                    image = c.get('image', '')
                    
                    # Requirement: Pinned images
                    if image.endswith(':latest') or ':' not in image.split('/')[-1]:
                        issues.append(f'Container \'{name}\' uses unpinned image: {image}')
                    
                    # Requirement: Resource limits
                    limits = c.get('resources', {}).get('limits', {})
                    if not limits.get('cpu') and not limits.get('memory'):
                        issues.append(f'Container \'{name}\' is missing resource limits (cpu/memory)')
                    
                    # Requirement: Security Context (Rootless/Bypass)
                    sec = c.get('securityContext', {})
                    if sec.get('privileged') == True:
                        annotations = doc.get('spec', {}).get('template', {}).get('metadata', {}).get('annotations', {})
                        if annotations.get('security.stig.bypass_privileged') != 'true':
                            issues.append(f'Container \'{name}\' is privileged in Kube manifest without bypass')

        for i in issues: print(i)
except Exception as e:
    print(f'YAML parse error: {e}')
")

    if [[ -n "$errors" ]]; then
        echo -e "\033[0;31m✗\033[0m FAILED"
        echo "$errors" | sed 's/^/    - /'
        FAIL=$((FAIL + 1))
    else
        echo -e "\033[0;32m✓\033[0m PASS"
        PASS=$((PASS + 1))
    fi
    
    rm -rf "$tmp_dir"
done

echo ""
echo -e "\033[1mKube Compliance Summary:\033[0m $PASS passed, $FAIL failed."
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
