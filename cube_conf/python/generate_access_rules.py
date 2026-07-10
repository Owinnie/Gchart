#!/usr/bin/env python3
"""Generate access_rules.yaml and optionally inject compile-time visibility flags.

Visibility injection rewrites model YAML in-place. That must only happen inside
Docker (image build or container-local /cube/conf), never against the git
checkout.

Set CUBE_INJECT_VISIBILITY=1 to enable injection (Dockerfile + start.sh do this).
Without it, only access_rules.yaml is written.
"""
import os
import yaml
import logging
from pathlib import Path
from datetime import datetime


def setup_logging():
    """Setup logging configuration."""
    log_dir = os.path.join("logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = os.path.join(log_dir, f"access_rules_{timestamp}.log")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler(),
        ],
    )
    return log_file


def inject_visibility_enabled() -> bool:
    return os.getenv("CUBE_INJECT_VISIBILITY", "").lower() in ("1", "true", "yes", "on")


def load_config():
    """Load access rules configuration."""
    config_file = "access_rules_config.yaml"
    with open(config_file, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def get_cube_name_from_file(file_path):
    """Extract cube name from a cube definition file."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()

        for line in content.split("\n"):
            if "name:" in line and not line.strip().startswith("#"):
                name = line.split("name:")[1].strip()
                name = name.strip("\"'")
                return name
    except Exception as e:
        logging.error(f"Error processing file {file_path}: {str(e)}")
    return None


def inject_visibility_flag(file_path, scopes):
    """
    Safely injects the public visibility flag into the YAML file using string manipulation.
    Handles existing public: false (skips) and public: true (replaces).

    Only runs when CUBE_INJECT_VISIBILITY is enabled (Docker build / start.sh).
    """
    if not inject_visibility_enabled():
        return

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        # If it already has the dynamic flag, skip injection
        if any("check_visibility" in line for line in lines):
            return

        # Pass 1: Determine the existing cube/view level public state
        cube_level_public_val = None
        in_def = False
        for line in lines:
            stripped = line.strip()
            if stripped in ["cubes:", "views:"]:
                in_def = True
            elif stripped in [
                "dimensions:",
                "measures:",
                "pre_aggregations:",
                "segments:",
                "joins:",
            ]:
                in_def = False

            if in_def:
                s_lower = stripped.lower()
                if s_lower in ["public: false", 'public: "false"', "public: 'false'"]:
                    cube_level_public_val = "false"
                    break
                elif s_lower in ["public: true", 'public: "true"', "public: 'true'"]:
                    cube_level_public_val = "true"
                    break

        # If it is explicitly set to false, respect it and touch nothing!
        if cube_level_public_val == "false":
            logging.info(
                f"Skipping {os.path.basename(file_path)} (cube explicitly marked public: false)"
            )
            return

        # Prepare the injection string
        if not scopes:
            flag_content = f'"{{{{ check_visibility([], COMPILE_CONTEXT) }}}}"'
        else:
            scopes_str = "', '".join(scopes)
            flag_content = (
                f"\"{{{{ check_visibility(['{scopes_str}'], COMPILE_CONTEXT) }}}}\""
            )

        # Pass 2: Rewrite the lines safely
        new_lines = []
        modified = False
        in_definition_section = False

        for line in lines:
            stripped = line.strip()

            if stripped in ["cubes:", "views:"]:
                in_definition_section = True
            elif stripped in [
                "dimensions:",
                "measures:",
                "pre_aggregations:",
                "segments:",
                "joins:",
            ]:
                in_definition_section = False

            # If replacing an existing public: true
            if cube_level_public_val == "true" and in_definition_section:
                if stripped.lower() in [
                    "public: true",
                    'public: "true"',
                    "public: 'true'",
                ]:
                    indent = line[: line.find("public:")]
                    new_lines.append(f"{indent}public: {flag_content}\n")
                    modified = True
                    continue  # Skip appending original line

            new_lines.append(line)

            # If no public flag existed, inject right below - name:
            if (
                cube_level_public_val is None
                and in_definition_section
                and stripped.startswith("- name:")
            ):
                indent = line[: line.find("- name:")] + "  "
                flag_line = f"{indent}public: {flag_content}\n"
                new_lines.append(flag_line)
                modified = True

        if modified:
            with open(file_path, "w", encoding="utf-8") as f:
                f.writelines(new_lines)

            action = (
                "Replaced 'public: true'"
                if cube_level_public_val == "true"
                else "Auto-injected"
            )
            logging.info(
                f"{action} compile-time visibility into {os.path.basename(file_path)}"
            )

    except Exception:
        logging.exception("Failed to inject flag into %s", file_path)


def find_cubes(base_dir: str, config: dict) -> dict:
    """Find all cube definition files, map their scopes, and inject visibility flags."""
    cubes = {}
    no_access_cubes = []

    public_directories = config.get("public_directories", [])
    public_cubes_list = config.get("public_cubes", [])

    for root, dirs, files in os.walk(base_dir):
        rel_path = os.path.relpath(root, base_dir)
        rel_path = rel_path.replace("\\", "/")

        if rel_path == ".":
            dir_name = os.path.basename(base_dir)
            check_path = dir_name
        else:
            path_parts = rel_path.split("/")
            dir_name = path_parts[-1] if len(path_parts) > 0 else None
            check_path = rel_path

        is_public_dir = check_path in public_directories

        for file in files:
            if file.endswith(".yml"):
                file_path = os.path.join(root, file)
                cube_name = get_cube_name_from_file(file_path)

                if cube_name:
                    if cube_name in config.get("special_cases", {}):
                        scopes = config["special_cases"][cube_name]["scope"]
                        cubes[cube_name] = scopes
                        inject_visibility_flag(file_path, scopes)
                        continue

                    if cube_name in public_cubes_list or is_public_dir:
                        scopes = ["default"]
                        cubes[cube_name] = scopes
                        inject_visibility_flag(file_path, scopes)
                        continue

                    directory_scopes = config.get("directory_scopes", {})
                    scope_config = directory_scopes.get(check_path) or (
                        directory_scopes.get(dir_name) if dir_name else None
                    )

                    if scope_config:
                        scopes = scope_config["scope"]
                        cubes[cube_name] = scopes
                        inject_visibility_flag(file_path, scopes)
                        continue

                    cubes[cube_name] = []
                    no_access_cubes.append(
                        {"cube": cube_name, "directory": check_path, "file": file_path}
                    )
                    inject_visibility_flag(file_path, [])

    return cubes, no_access_cubes


def generate_access_rules(base_dir, config):
    """Generate access rules based on cube directory structure."""
    cubes, no_access_cubes = find_cubes(base_dir, config)

    if no_access_cubes:
        logging.warning(
            "\nCubes with no access (not configured in access_rules_config.yaml):"
        )
        for cube_info in no_access_cubes:
            logging.warning(f"  - {cube_info['cube']}")
            logging.warning(f"    Directory: {cube_info['directory']}")
            logging.warning(f"    File: {cube_info['file']}")
        logging.warning(
            "\nTo grant access, add the directory to directory_scopes or public_directories in access_rules_config.yaml"
        )

    access_rules = {"restricted_cubes": {}, "restricted_dimensions": {}}

    for cube_name, scopes in cubes.items():
        access_rules["restricted_cubes"][cube_name] = {
            "scope": scopes if scopes else []
        }

    access_rules["restricted_dimensions"] = {
        dim: {"scope": dim_config["scope"]}
        for dim, dim_config in config.get("pii_dimensions", {}).items()
    }

    return access_rules


def main():
    log_file = setup_logging()
    logging.info("Starting access rules generation")
    if inject_visibility_enabled():
        logging.info(
            "CUBE_INJECT_VISIBILITY enabled — will rewrite model YAML in this working tree"
        )
    else:
        logging.info(
            "CUBE_INJECT_VISIBILITY disabled — writing access_rules.yaml only "
            "(no model YAML injection; set CUBE_INJECT_VISIBILITY=1 in Docker)"
        )

    config = load_config()
    logging.info("Loaded configuration from access_rules_config.yaml")

    base_dir_cubes = os.path.join("model", "cubes")
    base_dir_views = os.path.join("model", "views")

    logging.info("--- Processing Cubes ---")
    rules_cubes = generate_access_rules(base_dir_cubes, config)

    logging.info("--- Processing Views ---")
    rules_views = generate_access_rules(base_dir_views, config)

    final_access_rules = {
        "restricted_cubes": {
            **rules_cubes["restricted_cubes"],
            **rules_views["restricted_cubes"],
        },
        "restricted_dimensions": rules_cubes["restricted_dimensions"],
    }

    output_file = "access_rules.yaml"

    header = """# Access control rules for cubes and dimensions
# All cubes are restricted by default unless:
# 1. Their directory is listed in public_directories (assigned 'default' scope)
# 2. They are listed in public_cubes (assigned 'default' scope)
# Otherwise, they follow directory_scopes or special_cases rules
# This file is automatically generated - do not edit manually

"""

    try:
        with open(output_file, "w") as f:
            f.write(header)
            yaml.dump(
                final_access_rules,
                f,
                default_flow_style=False,
                sort_keys=False,
                default_style=None,
                indent=2,
            )
        logging.info(f"Successfully wrote access rules to {output_file}")
    except Exception as e:
        logging.error(f"Error writing access rules: {str(e)}")
        raise

    logging.info(f"Generated access rules written to {output_file}")
    logging.info(f"Log file created at {log_file}")


if __name__ == "__main__":
    main()
