import toml
from pathlib import Path
import sys

# Get the version from the command-line argument
version = sys.argv[1]

# Path to your pyproject.toml file
toml_file = Path('clients/python/percolate/pyproject.toml')

# Load the toml file
data = toml.load(toml_file)

# Set the version in pyproject.toml to the tag version
data['tool']['poetry']['version'] = version

# Write the changes back to the file
with toml_file.open('w') as f:
    toml.dump(data, f)

print(f"Updated pyproject.toml with version {version}")