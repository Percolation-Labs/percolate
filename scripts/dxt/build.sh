#!/bin/bash
# Build truly standalone MCP server with bundled dependencies

set -e

echo "Building standalone Percolate MCP Server with bundled dependencies..."

# Clean previous builds
rm -rf build
mkdir -p build

# Copy MCP server files
echo "Copying MCP server files..."
cp -r ../../clients/python/percolate/percolate/api/mcp_server ./build/

# Create directories
mkdir -p build/lib
mkdir -p build/wheels

# Build wheels for multiple Python versions (Claude Desktop might use different Python)
echo "Building wheels for multiple Python versions..."
echo "Current Python version: $(python --version)"

# Build for current Python version
pip wheel --wheel-dir build/wheels fastmcp httpx pydantic

# Try to build for Python 3.11 if available (Claude Desktop often uses this)
if command -v python3.11 >/dev/null 2>&1; then
    echo "Also building wheels for Python 3.11..."
    python3.11 -m pip wheel --wheel-dir build/wheels fastmcp httpx pydantic 2>/dev/null || echo "Python 3.11 wheel build failed, using existing wheels"
fi

# Try to build for Python 3.12 if available
if command -v python3.12 >/dev/null 2>&1; then
    echo "Also building wheels for Python 3.12..."
    python3.12 -m pip wheel --wheel-dir build/wheels fastmcp httpx pydantic 2>/dev/null || echo "Python 3.12 wheel build failed, using existing wheels"
fi

echo "Available wheels:"
ls -la build/wheels/*.whl | head -10

# Create the wheel installer
cat > build/lib/__init__.py << 'EOF'
"""Platform-specific wheel loader for bundled dependencies"""
import sys
import os
import platform
import zipfile
import subprocess

def extract_wheel(wheel_path, target_dir):
    """Extract wheel contents to target directory including metadata"""
    print(f"Extracting {os.path.basename(wheel_path)} to {target_dir}", file=sys.stderr)
    with zipfile.ZipFile(wheel_path, 'r') as wheel:
        for name in wheel.namelist():
            # Extract everything including dist-info metadata
            try:
                wheel.extract(name, target_dir)
                if 'pydantic_core' in name:
                    print(f"  Extracted pydantic_core file: {name}", file=sys.stderr)
                elif '.dist-info/' in name and 'METADATA' in name:
                    print(f"  Extracted metadata file: {name}", file=sys.stderr)
            except Exception as e:
                print(f"  Failed to extract {name}: {e}", file=sys.stderr)

# On import, extract wheels for this platform
wheels_dir = os.path.join(os.path.dirname(__file__), '..', 'wheels')
lib_dir = os.path.dirname(__file__)

if os.path.exists(wheels_dir) and not os.path.exists(os.path.join(lib_dir, '_wheels_extracted')):
    print(f"Extracting wheels for platform: {platform.system()} {platform.machine()}", file=sys.stderr)
    print(f"Wheels directory: {wheels_dir}", file=sys.stderr)
    print(f"Available wheels: {[f for f in os.listdir(wheels_dir) if f.endswith('.whl')]}", file=sys.stderr)
    
    for wheel_file in sorted(os.listdir(wheels_dir)):
        if wheel_file.endswith('.whl'):
            wheel_path = os.path.join(wheels_dir, wheel_file)
            try:
                extract_wheel(wheel_path, lib_dir)
                print(f"✓ Extracted wheel: {wheel_file}", file=sys.stderr)
            except Exception as e:
                print(f"✗ Failed to extract {wheel_file}: {e}", file=sys.stderr)
    
    # Check what was actually extracted
    print(f"Final lib directory contents: {os.listdir(lib_dir)}", file=sys.stderr)
    
    # Mark as extracted
    with open(os.path.join(lib_dir, '_wheels_extracted'), 'w') as f:
        f.write('done')
        
# Also check if pydantic_core is available after extraction
if os.path.exists(os.path.join(lib_dir, '_wheels_extracted')):
    pydantic_core_path = os.path.join(lib_dir, 'pydantic_core')
    if os.path.exists(pydantic_core_path):
        print(f"pydantic_core found at: {pydantic_core_path}", file=sys.stderr)
        print(f"pydantic_core contents: {os.listdir(pydantic_core_path)}", file=sys.stderr)
    else:
        print(f"⚠️  pydantic_core NOT found in {lib_dir}", file=sys.stderr)
EOF

# Note: fastmcp version detection fix will be applied at runtime
# since wheels now include proper metadata

echo "Build complete! Standalone MCP server with bundled dependencies ready in build/"
echo "Package size: $(du -sh build | cut -f1)"
echo "Wheels collected: $(ls -1 build/wheels/*.whl 2>/dev/null | wc -l)"

# Package into DXT file
echo "Packaging into DXT extension..."
dxt pack . percolate-mcp.dxt

# Clean existing installation and install the new DXT file
echo "Installing DXT extension to Claude Desktop..."
if [ -d "/Users/sirsh/Library/Application Support/Claude/Claude Extensions/local.dxt.percolation-labs.percolate-mcp" ]; then
    rm -rf "/Users/sirsh/Library/Application Support/Claude/Claude Extensions/local.dxt.percolation-labs.percolate-mcp"
fi

# Unpack the DXT file to Claude's extension directory
dxt unpack percolate-mcp.dxt "/Users/sirsh/Library/Application Support/Claude/Claude Extensions/local.dxt.percolation-labs.percolate-mcp"

echo "✅ DXT extension updated and installed to Claude Desktop!"
echo "   Location: /Users/sirsh/Library/Application Support/Claude/Claude Extensions/local.dxt.percolation-labs.percolate-mcp"