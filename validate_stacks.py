import yaml
import glob
import sys
import os

def check_stack(filepath):
    errors = []
    try:
        with open(filepath, 'r') as f:
            data = yaml.safe_load(f)
    except Exception as e:
        return [f"Failed to parse YAML: {e}"]

    if not data or not isinstance(data, dict):
        return ["Empty or invalid YAML file"]

    services = data.get("services", {})
    for service_name, service in services.items():
        # Check image tag
        image = service.get("image", "")
        if not image:
            errors.append(f"Service '{service_name}' missing 'image' definition.")
        elif image.endswith(":latest") or ":" not in image.split("/")[-1]:
            # This is a basic check. If there's no colon in the last part, it's implicitly latest, unless it's a digest
            if "@sha256:" not in image and (image.endswith(":latest") or ":" not in image.split("/")[-1]):
                errors.append(f"Service '{service_name}' uses unpinned or latest image: '{image}'")

        # Check deploy.resources.limits
        deploy = service.get("deploy", {})
        resources = deploy.get("resources", {})
        limits = resources.get("limits", {})
        if not limits:
            errors.append(f"Service '{service_name}' missing 'deploy.resources.limits'.")

        # Check healthcheck
        healthcheck = service.get("healthcheck", {})
        if not healthcheck and "disable: true" not in str(healthcheck):
            # some services might explicitly disable healthcheck, but generally they must define it
            errors.append(f"Service '{service_name}' missing 'healthcheck'.")

        # Check volumes use ${DATA_DIR}
        volumes = service.get("volumes", [])
        for vol in volumes:
            if isinstance(vol, str):
                host_path = vol.split(":")[0]
                if not host_path.startswith("./") and not host_path.startswith("${DATA_DIR}") and not host_path.startswith("/var/run/"):
                     errors.append(f"Service '{service_name}' uses absolute or non-DATA_DIR volume: '{host_path}'")
            elif isinstance(vol, dict):
                host_path = vol.get("source", "")
                if not host_path.startswith("./") and not host_path.startswith("${DATA_DIR}") and not host_path.startswith("/var/run/"):
                     errors.append(f"Service '{service_name}' uses non-DATA_DIR volume source: '{host_path}'")
                     
    networks = data.get("networks", {})
    for net_name, net in networks.items():
        if isinstance(net, dict):
            # Just flag if it's explicitly not internal or doesn't have it (might be a warning)
            # In practice, frontend networks aren't internal.
            pass

    return errors

def main():
    stack_files = glob.glob("stacks/*/docker-compose.yml")
    all_errors = {}
    for filepath in stack_files:
        if "_template" in filepath:
            continue
        errors = check_stack(filepath)
        if errors:
            all_errors[filepath] = errors

    if all_errors:
        for filepath, errors in all_errors.items():
            print(f"\\n--- {filepath} ---")
            for error in errors:
                print(f"  - {error}")
        sys.exit(1)
    else:
        print("All stacks comply with GEMINI.md rules!")

if __name__ == "__main__":
    main()
