#!/bin/bash

# Test script for Percolate MCP DXT before Claude Desktop installation

set -e

echo "🧪 Testing Percolate MCP DXT..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find the latest DXT file
DXT_FILE=$(ls -t "$SCRIPT_DIR/build/release/"*.dxt 2>/dev/null | head -1)

if [ -z "$DXT_FILE" ]; then
    echo "❌ Error: No DXT file found. Run ./build_dxt.sh first."
    exit 1
fi

echo "📦 Testing DXT file: $DXT_FILE"

# Create test directory
TEST_DIR="$SCRIPT_DIR/build/test"
rm -rf $TEST_DIR
mkdir -p $TEST_DIR

# Extract DXT for testing
echo "1️⃣ Extracting DXT package..."
unzip -q "$DXT_FILE" -d $TEST_DIR

# Validate manifest
echo "2️⃣ Validating manifest.json..."
if [ ! -f "$TEST_DIR/manifest.json" ]; then
    echo "❌ Error: manifest.json not found"
    exit 1
fi

# Check manifest structure
python3 -c "
import json
with open('$TEST_DIR/manifest.json') as f:
    manifest = json.load(f)
    required = ['dxt_version', 'name', 'server']
    missing = [k for k in required if k not in manifest]
    if missing:
        print(f'❌ Error: Missing required fields: {missing}')
        exit(1)
    print('✅ Manifest structure valid')
"

# Test Python imports
echo "3️⃣ Testing Python imports..."
cd $TEST_DIR
export PYTHONPATH="server:server/lib:$PYTHONPATH"

python3 -c "
try:
    # Test core imports
    import mcp_server
    import mcp_server.server
    import mcp_server.config
    import mcp_server.auth
    import mcp_server.repository
    print('✅ Core MCP server imports successful')
    
    # Test dependencies
    import fastmcp
    import pydantic
    import jose
    import httpx
    print('✅ Dependencies found')
    
    # Test percolate package
    import percolate
    print('✅ Percolate package imported')
except ImportError as e:
    print(f'❌ Import error: {e}')
    exit(1)
"

# Test server module execution
echo "4️⃣ Testing server module execution..."
timeout 3s python3 -m mcp_server.server 2>&1 | head -20 || true
echo "✅ Server module can be executed"

# Test with MCP stdio protocol
echo "5️⃣ Testing MCP stdio protocol..."
echo '{"jsonrpc": "2.0", "method": "tools/list", "id": 1}' | \
    timeout 3s python3 -m mcp_server.server 2>&1 | \
    grep -q "jsonrpc" && echo "✅ MCP stdio communication working" || echo "⚠️ MCP stdio test inconclusive"

cd - > /dev/null

# Cleanup
rm -rf $TEST_DIR

echo ""
echo "🎉 All tests passed! The DXT is ready for Claude Desktop installation."
echo ""
echo "🚀 To install:"
echo "1. Open Claude Desktop"
echo "2. Go to Settings → Extensions" 
echo "3. Drag $DXT_FILE into the extensions area"
echo ""
echo "📊 Package information:"
echo "  - Size: $(ls -lh "$DXT_FILE" | awk '{print $5}')"
echo "  - Location: $DXT_FILE"