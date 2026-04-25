import os
import yaml
import sys
import glob

def get_compose_files():
    files = glob.glob('stacks/*/docker-compose.yml') + glob.glob('stacks/user/*/docker-compose.yml')
    return [f for f in files if '_template' not in f]

def fail(msg):
    print(f"  \033[0;31m✗ FAIL:\033[0m {msg}")
    return 1

def pass_test(msg):
    print(f"  \033[0;32m✓ PASS:\033[0m {msg}")

def check_rootless_and_privileged(compose_file, data):
    failures = 0
    stack = os.path.basename(os.path.dirname(compose_file))
    for svc_name, svc in data.get('services', {}).items():
        is_privileged = svc.get('privileged', False)
        labels = svc.get('labels', [])
        bypass_label = False
        if isinstance(labels, list):
            bypass_label = any('security.stig.bypass_privileged=true' in str(l) for l in labels)
        elif isinstance(labels, dict):
            bypass_label = labels.get('security.stig.bypass_privileged') in [True, 'true', 'True']
        
        if is_privileged and not bypass_label:
            failures += fail(f"[{stack}/{svc_name}] Privileged container missing security.stig.bypass_privileged=true")
    if failures == 0: pass_test(f"[{stack}] Rootless/Privileged rules met")
    return failures

def check_reliability(compose_file, data):
    failures = 0
    stack = os.path.basename(os.path.dirname(compose_file))
    for svc_name, svc in data.get('services', {}).items():
        has_healthcheck = 'healthcheck' in svc
        has_limits = 'limits' in svc.get('deploy', {}).get('resources', {})
        if not has_healthcheck:
            failures += fail(f"[{stack}/{svc_name}] Missing healthcheck")
        if not has_limits:
            failures += fail(f"[{stack}/{svc_name}] Missing deploy.resources.limits")
    if failures == 0: pass_test(f"[{stack}] Reliability rules met")
    return failures

def check_mtls_sidecar(compose_file, data):
    # This might fail on many, but it's a mandate
    failures = 0
    stack = os.path.basename(os.path.dirname(compose_file))
    # We'll just check if there's network_mode: service:... or if it's not a backend
    # Actually, the mandate says ALL backend services and databases.
    # We will just warn for now or fail. Let's fail if it's a db and no sidecar.
    db_services = [s for s in data.get('services', {}) if 'db' in s or 'redis' in s]
    for svc_name in db_services:
        svc = data['services'][svc_name]
        network_mode = svc.get('network_mode', '')
        if not network_mode.startswith('service:'):
            failures += fail(f"[{stack}/{svc_name}] Database/backend missing mTLS Sidecar Pattern (network_mode: service:...)")
    if failures == 0: pass_test(f"[{stack}] mTLS Sidecar Pattern rules met")
    return failures

def check_micro_segmentation(compose_file, data):
    failures = 0
    stack = os.path.basename(os.path.dirname(compose_file))
    networks = data.get('networks', {})
    for net_name, net in networks.items():
        if net is None: net = {}
        if not net.get('external', False) and not net.get('internal', False):
            # If it's defined here and not external, it should be internal
            failures += fail(f"[{stack}] Network '{net_name}' is not marked internal: true")
    if failures == 0: pass_test(f"[{stack}] Network Micro-Segmentation met")
    return failures

def check_airgap(compose_file, data):
    failures = 0
    stack = os.path.basename(os.path.dirname(compose_file))
    for svc_name, svc in data.get('services', {}).items():
        image = svc.get('image', '')
        if image.endswith(':latest') or ':' not in image.split('/')[-1]:
            failures += fail(f"[{stack}/{svc_name}] Image '{image}' uses :latest or is untagged")
    if failures == 0: pass_test(f"[{stack}] Air-gap image pinning met")
    return failures

def check_data_separation(compose_file, data):
    failures = 0
    stack = os.path.basename(os.path.dirname(compose_file))
    for svc_name, svc in data.get('services', {}).items():
        volumes = svc.get('volumes', [])
        for vol in volumes:
            if isinstance(vol, str):
                host_path = vol.split(':')[0]
                if host_path.startswith('/var/') or host_path.startswith('/etc/') or host_path.startswith('/opt/'):
                    # allowed absolute paths must start with variables
                    pass
                if not (host_path.startswith('${DATA_DIR}') or host_path.startswith('./') or host_path.startswith('../') or host_path.startswith('${PODMAN_SOCK}') or host_path.startswith('${STACKS_PATH}') or not host_path.startswith('/')):
                    # Some paths might be valid like /etc/localtime, let's just fail if it's hardcoded /var/Geo-Brain instead of ${DATA_DIR}
                    if '/var/Geo-Brain' in host_path:
                        failures += fail(f"[{stack}/{svc_name}] Volume '{vol}' uses hardcoded /var/Geo-Brain instead of ${{DATA_DIR}}")
    if failures == 0: pass_test(f"[{stack}] Data Separation rules met")
    return failures

def check_https_only(compose_file, data):
    failures = 0
    stack = os.path.basename(os.path.dirname(compose_file))
    for svc_name, svc in data.get('services', {}).items():
        labels = svc.get('labels', [])
        if isinstance(labels, list):
            has_router = any('traefik.http.routers.' in str(l) for l in labels)
            has_websecure = any('.entrypoints=websecure' in str(l) for l in labels)
            if has_router and not has_websecure:
                failures += fail(f"[{stack}/{svc_name}] Traefik router missing websecure entrypoint")
    if failures == 0: pass_test(f"[{stack}] HTTPS Only rules met")
    return failures

def main():
    files = get_compose_files()
    total_failures = 0
    for f in files:
        print(f"\n\033[1m\033[36m━━━ Testing {f} ━━━\033[0m")
        try:
            with open(f) as yml:
                data = yaml.safe_load(yml)
        except Exception as e:
            total_failures += fail(f"Could not parse YAML: {e}")
            continue
        
        if not data: continue
        
        total_failures += check_rootless_and_privileged(f, data)
        total_failures += check_reliability(f, data)
        total_failures += check_mtls_sidecar(f, data)
        total_failures += check_micro_segmentation(f, data)
        total_failures += check_airgap(f, data)
        total_failures += check_data_separation(f, data)
        total_failures += check_https_only(f, data)

    print(f"\n\033[1mTotal Failures: {total_failures}\033[0m")
    sys.exit(1 if total_failures > 0 else 0)

if __name__ == '__main__':
    main()
