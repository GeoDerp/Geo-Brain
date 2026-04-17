import yaml
import glob
import sys
import os
import re

def parse_duration(duration_str):
    total_seconds = 0
    matches = re.findall(r'(\d+)([hms])', str(duration_str))
    for val, unit in matches:
        if unit == 'h':
            total_seconds += int(val) * 3600
        elif unit == 'm':
            total_seconds += int(val) * 60
        elif unit == 's':
            total_seconds += int(val)
    return total_seconds

def check_stack(filepath):
    errors = []
    warnings = []
    try:
        with open(filepath, 'r') as f:
            data = yaml.safe_load(f)
    except Exception as e:
        return [f"Failed to parse YAML: {e}"], []

    if not data or not isinstance(data, dict):
        return [], []

    services = data.get("services", {})
    for service_name, service in services.items():
        # Check image tag
        image = service.get("image", "")
        if not image:
            errors.append(f"Service '{service_name}' missing 'image' definition.")
        elif "@sha256:" not in image and "@sha512:" not in image:
            if image.endswith(":latest") or ":" not in image.split("/")[-1]:
                errors.append(f"Service '{service_name}' uses unpinned or latest image: '{image}'")

        # Check deploy.resources.limits (must have actual values)
        deploy = service.get("deploy", {})
        resources = deploy.get("resources", {})
        limits = resources.get("limits", {})
        if not limits or not any(limits.values()):
            errors.append(f"Service '{service_name}' missing 'deploy.resources.limits'.")

        # Check healthcheck
        healthcheck = service.get("healthcheck")
        if not healthcheck:
            errors.append(f"Service '{service_name}' missing 'healthcheck'.")
        elif isinstance(healthcheck, dict):
            if healthcheck.get("disable") is True:
                pass  # Explicitly disabled is acceptable
            else:
                interval = healthcheck.get("interval", "")
                if interval and parse_duration(interval) > 60:
                    errors.append(f"Service '{service_name}' has healthcheck interval > 60s: '{interval}'")

        # Check security_opt: no-new-privileges
        security_opt = service.get("security_opt", [])
        has_no_new_priv = any("no-new-privileges" in str(s) for s in security_opt)
        is_privileged = service.get("privileged", False)
        labels = service.get("labels", [])
        label_str = str(labels)
        has_bypass = "security.stig.bypass_privileged=true" in label_str

        if not has_no_new_priv and not has_bypass:
            warnings.append(f"Service '{service_name}' missing 'security_opt: no-new-privileges:true'.")

        # Check cap_drop: ALL
        cap_drop = service.get("cap_drop", [])
        if "ALL" not in cap_drop and not has_bypass:
            warnings.append(f"Service '{service_name}' missing 'cap_drop: ALL'.")

        # Check privileged without bypass label
        if is_privileged and not has_bypass:
            errors.append(f"Service '{service_name}' uses 'privileged: true' without 'security.stig.bypass_privileged=true' label.")

        # Check security.stig labels
        if "security.stig.compliance=true" not in label_str and "security.stig" not in label_str:
            warnings.append(f"Service '{service_name}' missing 'security.stig' labels.")

        # Check volumes use ${DATA_DIR}
        volumes = service.get("volumes", [])
        for vol in volumes:
            if isinstance(vol, str):
                if "}:" in vol:
                    host_path = vol.split("}:")[0] + "}"
                else:
                    host_path = vol.split(":")[0]

                allowed_prefixes = ("./", "../", "${DATA_DIR}", "/var/run/", "/dev", "/proc", "/etc", "/var/log", "${PODMAN_SOCK}", "${PODMAN_SOCK:-", "${STACKS_PATH}")
                if not any(host_path.startswith(prefix) for prefix in allowed_prefixes) and not host_path.isalnum() and "-" not in host_path and "_" not in host_path:
                    # Ignore named volumes (e.g. defectdojo-static, pgdata)
                    if host_path.startswith("/") or host_path.startswith("./") or host_path.startswith("${"):
                        errors.append(f"Service '{service_name}' uses absolute or non-DATA_DIR volume: '{host_path}'")
            elif isinstance(vol, dict):
                host_path = vol.get("source", "")
                allowed_prefixes = ("./", "../", "${DATA_DIR}", "/var/run/", "/dev", "/proc", "/etc", "/var/log", "${PODMAN_SOCK}", "${PODMAN_SOCK:-", "${STACKS_PATH}")
                if not any(host_path.startswith(prefix) for prefix in allowed_prefixes) and not host_path.isalnum() and "-" not in host_path and "_" not in host_path:
                    if host_path.startswith("/") or host_path.startswith("./") or host_path.startswith("${"):
                        errors.append(f"Service '{service_name}' uses non-DATA_DIR volume source: '{host_path}'")

    # Check networks
    networks = data.get("networks", {})
    for net_name, net in (networks or {}).items():
        if not isinstance(net, dict):
            continue
        is_external = net.get("external", False)
        is_internal = net.get("internal", False)
        # Non-external, non-internal networks that aren't proxy/waf are suspect
        if not is_external and not is_internal:
            if net_name not in ("proxy-net", "waf-net"):
                errors.append(f"Network '{net_name}' is not marked 'internal: true' and is not external. Backend networks should be internal.")

    return errors, warnings

def main():
    if len(sys.argv) > 1:
        stack_files = sys.argv[1:]
    else:
        stack_files = sorted(glob.glob("stacks/*/docker-compose.yml") + glob.glob("stacks/user/*/docker-compose.yml"))

    all_errors = {}
    all_warnings = {}
    for filepath in stack_files:
        if "_template" in filepath:
            continue
        errors, warnings = check_stack(filepath)
        if errors:
            all_errors[filepath] = errors
        if warnings:
            all_warnings[filepath] = warnings

    has_issues = False
    if all_warnings:
        for filepath, warnings in all_warnings.items():
            print(f"\n--- {filepath} ---")
            for w in warnings:
                print(f"  [WARN] {w}")

    if all_errors:
        has_issues = True
        for filepath, errors in all_errors.items():
            print(f"\n--- {filepath} ---")
            for error in errors:
                print(f"  [ERROR] {error}")
        print(f"\nValidation FAILED with errors in {len(all_errors)} stack(s).")
        sys.exit(1)
    else:
        print("\nAll stacks comply with GEMINI.md rules!")

if __name__ == "__main__":
    main()