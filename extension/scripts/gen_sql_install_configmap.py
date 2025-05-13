import os
import re
import argparse
import subprocess


def sanitize_name(filename):
    """Convert a filename into a valid Kubernetes resource name."""
    name = filename.lower().replace("_", "-")
    name = re.sub(r"[^a-z0-9.-]", "-", name)  # Replace invalid characters
    name = re.sub(r"^-+|-+$", "", name)  # Trim leading/trailing dashes
    return name[:63]  # Max length for a Kubernetes name


def generate_configmaps(
    input_folder="../sql", output_folder=".", namespace="p8", apply=False
):
    os.makedirs(output_folder, exist_ok=True)
    configmap_folder = os.path.join(output_folder, "configmaps")
    os.makedirs(configmap_folder, exist_ok=True)

    sql_files = sorted(
        [f for f in os.listdir(input_folder) if f.endswith(".sql")],
        key=lambda x: int(re.match(r"(\d+)", x).group())
        if re.match(r"(\d+)", x)
        else float("inf"),
    )

    config_refs = []

    for file in sql_files:
        file_path = os.path.join(input_folder, file)
        valid_name = sanitize_name(os.path.splitext(file)[0])
        configmap_path = os.path.join(configmap_folder, f"{valid_name}.yaml")

        # Read SQL content and get file size
        with open(file_path, "r") as infile:
            sql_content = infile.read()
        file_size = os.path.getsize(file_path)

        # Generate ConfigMap YAML
        configmap_yaml = f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: {valid_name}
  namespace: {namespace}
data:
  {file}: |
"""
        for line in sql_content.splitlines():
            configmap_yaml += f"    {line}\n"

        # Save ConfigMap YAML
        with open(configmap_path, "w") as cm_file:
            cm_file.write(configmap_yaml)

        print(f"✅ ConfigMap for {file} saved to {configmap_path} ({file_size} bytes)")

        # Apply ConfigMap using kubectl if --apply flag is set
        if apply:
            try:
                subprocess.run(["kubectl", "apply", "-f", configmap_path], check=True)
                print(f"🚀 Applied {configmap_path} successfully.")
            except subprocess.CalledProcessError:
                print(
                    f"❌ Failed to apply {configmap_path}. Check Kubernetes configuration."
                )

        # Add to config references
        config_refs.append(f"    - name: {valid_name}\n      key: {file}")

    print(f"\n📂 All ConfigMaps saved in {configmap_folder}")

    # Print bootstrap instructions
    print("\n📌 Add the following to your cluster bootstrap configuration:")
    print("\n```yaml")
    print("postInitApplicationSQLRefs:")
    print("  configMapRefs:")
    for ref in config_refs:
        print(ref)
    print("```\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate Kubernetes ConfigMaps for SQL files"
    )
    parser.add_argument(
        "--input-folder",
        default="../sql",
        help="Folder containing SQL files (default: ../sql)",
    )
    parser.add_argument(
        "--output-folder", default=".", help="Folder to save ConfigMaps (default: .)"
    )
    parser.add_argument(
        "--namespace", default="p8", help="Kubernetes namespace (default: test)"
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply the generated ConfigMaps using kubectl",
    )

    args = parser.parse_args()
    generate_configmaps(
        args.input_folder, args.output_folder, args.namespace, args.apply
    )
