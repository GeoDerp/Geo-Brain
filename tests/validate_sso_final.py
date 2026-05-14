import requests
import sys
import os

_repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Auto-load .env if DOMAIN is not already in the environment
def _load_env(env_path):
    if not os.path.isfile(env_path):
        return
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, _, val = line.partition('=')
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = val

if not os.environ.get("DOMAIN"):
    _load_env(os.path.join(_repo_root, ".env"))

domain = os.environ.get("DOMAIN", "example.local")
# Use the homelab CA bundle if available; fall back to system trust store.
_ca_candidates = [
    os.environ.get("CA_CERT"),
    os.path.join(_repo_root, "stacks", "traefik", "config", "certs", "ca-bundle.crt"),
    os.path.join(_repo_root, "certs", "ca.crt"),
    os.path.join(_repo_root, "stacks", "traefik", "config", "certs", "root_ca.crt"),
]
verify = next((p for p in _ca_candidates if p and os.path.isfile(p)), True)

clients = {
    "grafana": f"https://grafana.{domain}/login/generic_oauth",
    "gitea": f"https://gitea.{domain}/user/oauth2/kanidm",
    "quay": f"https://quay.{domain}/signin",
    "defectdojo": f"https://defectdojo.{domain}/login/oidc/",
    "moodle": f"https://moodle.{domain}/auth/oauth2/login.php?id=1",
    "oauth2-proxy": f"https://{domain}"
}

print(f"{'Stack':<15} | {'Discovery':<10} | {'Status':<20}")
print("-" * 50)

all_passed = True

for name, url in clients.items():
    # 1. Check Discovery
    client_id = "oauth2-proxy" if name == "oauth2-proxy" else name
    discovery_url = f"https://kanidm.{domain}/oauth2/openid/{client_id}/.well-known/openid-configuration"
    
    discovery_ok = False
    try:
        r = requests.get(discovery_url, verify=verify, timeout=5)
        if r.status_code == 200:
            discovery_ok = True
    except requests.RequestException as e:
        print(f"  [WARN] Discovery request failed for {name}: {e}")

    # 2. Check Integration
    status = "FAIL"
    try:
        r = requests.get(url, verify=verify, timeout=5, allow_redirects=False)
        
        location = r.headers.get("Location", "")
        
        # Immediate 302 to Kanidm
        if r.status_code in [301, 302, 303, 307, 308] and "kanidm" in location.lower():
            status = "✅ 302 Redirect"
        
        # UI with OIDC Button (200)
        elif r.status_code == 200:
            body = r.text.lower()
            if "kanidm" in body or "oidc" in body or "openid" in body:
                status = "✅ OIDC UI Button"
            else:
                status = "❌ No OIDC UI"
                all_passed = False
        
        # OAuth2 Proxy (401 or 403 UI)
        elif r.status_code in [401, 403]:
            body = r.text.lower()
            if "kanidm" in location.lower() or "sign in with kanidm" in body:
                status = "✅ Auth Proxy UI"
            else:
                status = "❌ Proxy No UI"
                all_passed = False
        
        # Moodle Specific (Missing sesskey but OIDC configured)
        elif name == "moodle" and "sesskey" in r.text:
             status = "✅ OIDC Ready (Manual)"

        else:
            status = f"❌ Unexpected {r.status_code}"
            all_passed = False

    except Exception as e:
        status = f"ERR: {str(e)[:10]}"
        all_passed = False

    if not discovery_ok:
        all_passed = False

    disc_str = "OK" if discovery_ok else "FAIL"
    print(f"{name:<15} | {disc_str:<10} | {status:<20}")

if not all_passed:
    print("\n❌ SSO Validation Failed. Some endpoints are incorrectly configured.")
    sys.exit(1)
else:
    print("\n✅ All SSO integrations passed validation.")
    sys.exit(0)

