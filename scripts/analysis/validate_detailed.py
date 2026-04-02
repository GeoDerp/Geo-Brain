import yaml
import glob
import os

stacks = glob.glob("stacks/**/docker-compose.yml", recursive=True)
results = []

for stack in stacks:
    if "_template" in stack: continue
    with open(stack, 'r') as f:
        try:
            data = yaml.safe_load(f)
            if not data or 'services' not in data:
                continue
            for service_name, service in data['services'].items():
                health = "✅" if 'healthcheck' in service else "❌"
                limits = "✅" if 'deploy' in service and 'resources' in service['deploy'] and 'limits' in service['deploy']['resources'] else "❌"
                rootless = "✅" if 'security_opt' in service and 'no-new-privileges:true' in str(service['security_opt']) else "❌"
                oidc = "✅" if any("OIDC" in str(v) or "OPENID" in str(v) for v in service.get('environment', [])) else "❌"
                results.append(f"| {os.path.basename(os.path.dirname(stack)):<15} | {service_name:<20} | {health} | {limits} | {rootless} | {oidc} |")
        except Exception as e:
            print(f"Error parsing {stack}: {e}")

print("| Stack           | Service              | Health | Limits | NoNewPriv | OIDC |")
print("|-----------------|----------------------|--------|--------|-----------|------|")
for res in sorted(results):
    print(res)
