import toml
from pathlib import Path
import sys

# Get the version from the command-line argument
version = sys.argv[1]

# Path to your pyproject.toml file - assume we are running this script from the root of the python project
toml_file = Path('pyproject.toml')

# Load the toml file
data = toml.load(toml_file)

# Set the version in pyproject.toml to the tag version
data['tool']['poetry']['version'] = version

# Write the changes back to the file
with toml_file.open('w') as f:
    toml.dump(data, f)
    
with open("__version__", 'w') as f:
    f.write(version)

print(f"Updated pyproject.toml with version {version}")