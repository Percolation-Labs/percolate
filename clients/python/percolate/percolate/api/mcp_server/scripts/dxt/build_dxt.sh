#!/bin/bash

# Build script for Percolate MCP Desktop Extension
# Based on reference implementation from mcp-ataccama

set -e

echo "🔧 Building Percolate MCP Desktop Extension..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PERCOLATE_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"

# Create a temporary dxt directory for building
TEMP_DXT_DIR="$SCRIPT_DIR/build/temp_dxt"
mkdir -p $TEMP_DXT_DIR

# Clean previous build
rm -rf $TEMP_DXT_DIR/server
rm -f "$SCRIPT_DIR/build/release/*.dxt"

# Copy manifest to temp directory
echo "📄 Copying manifest..."
cp "$SCRIPT_DIR/manifest.json" $TEMP_DXT_DIR/

# Create server directory
echo "📂 Setting up server directory..."
mkdir -p $TEMP_DXT_DIR/server

# Copy the entire MCP server module to maintain proper Python package structure
echo "📦 Copying MCP server source..."
cp -r "$PROJECT_ROOT" $TEMP_DXT_DIR/server/mcp_server

# Copy the main percolate package for dependencies
echo "📚 Copying percolate package..."
cp -r "$PERCOLATE_ROOT/percolate" $TEMP_DXT_DIR/server/

# Verify that all MCP components are included
echo "🔍 Verifying MCP components..."
echo "  Tools found: $(find $TEMP_DXT_DIR/server -name "*_tools.py" | wc -l)"
echo "  Server files: $(find $TEMP_DXT_DIR/server -name "server.py" | wc -l)"
echo "  Config files: $(find $TEMP_DXT_DIR/server -name "config.py" | wc -l)"

# Create requirements file from dependencies
echo "📋 Creating requirements file..."
cat > $TEMP_DXT_DIR/server/requirements.txt << EOF
fastmcp>=2.10.1
pydantic>=2.0.0
python-jose[cryptography]>=3.3.0
httpx>=0.27.0
fastapi>=0.110.1
uvicorn>=0.17.0
loguru>=0.7.3
openai>=1.0
typer>=0.11.0
pyyaml>=6.0.2
tenacity>=8.0.0
docstring-parser>=0.16
psycopg2-binary>=2.0.0
EOF

echo "📦 Requirements created:"
echo "  Total packages: $(grep -v '^$' $TEMP_DXT_DIR/server/requirements.txt | wc -l)"

# Install dependencies in a lib folder for DXT (following official docs)
echo "🔧 Installing dependencies..."
mkdir -p $TEMP_DXT_DIR/server/lib
# Force arm64 architecture for Apple Silicon (following reference implementation)
export ARCHFLAGS="-arch arm64"
pip install --platform macosx_11_0_arm64 --python-version 3.11 --only-binary :all: -r $TEMP_DXT_DIR/server/requirements.txt --target $TEMP_DXT_DIR/server/lib --upgrade

# Remove unnecessary files to reduce package size
echo "🧹 Cleaning up unnecessary files..."
find $TEMP_DXT_DIR/server -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find $TEMP_DXT_DIR/server -type f -name "*.pyc" -delete 2>/dev/null || true
find $TEMP_DXT_DIR/server -type f -name "*.pyo" -delete 2>/dev/null || true
find $TEMP_DXT_DIR/server -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
find $TEMP_DXT_DIR/server/lib -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find $TEMP_DXT_DIR/server/lib -type d -name "test" -exec rm -rf {} + 2>/dev/null || true

# Validate and create the DXT package using the official tool
echo "📦 Validating and creating DXT package..."
cd $TEMP_DXT_DIR

# Check if npx and dxt are available
if ! command -v npx &> /dev/null; then
    echo "❌ Error: npx not found. Please install Node.js."
    exit 1
fi

# Use the official Anthropic DXT tool
npx @anthropic-ai/dxt pack
cd - > /dev/null

# Move the generated DXT to the build directory with proper naming
mkdir -p "$SCRIPT_DIR/build/release"
# Extract version from manifest
VERSION=$(grep '"version"' "$SCRIPT_DIR/manifest.json" | grep -v "dxt_version" | head -1 | cut -d'"' -f4)
# Move and rename the file
mv $TEMP_DXT_DIR/*.dxt "$SCRIPT_DIR/build/release/percolate-mcp-${VERSION}.dxt"

# Clean up
echo "🧹 Cleaning up..."
rm -rf $TEMP_DXT_DIR

# Get the actual filename
DXT_FILE=$(ls "$SCRIPT_DIR/build/release/"*.dxt 2>/dev/null | head -1)

echo "✅ Build complete! Extension created: ${DXT_FILE}"
echo ""
echo "📦 Package size: $(ls -lh "$SCRIPT_DIR/build/release/"*.dxt | awk '{print $5}')"
echo ""
echo "🚀 To install:"
echo "1. Open Claude Desktop"
echo "2. Go to Settings → Extensions"
echo "3. Drag the DXT file into the extensions area"
echo "4. Select ${DXT_FILE}"
echo ""
echo "🔧 Environment variables configured:"
echo "- P8_API_ENDPOINT: Percolate API endpoint URL"
echo "- P8_API_KEY: Bearer token for authentication"
echo "- P8_OAUTH_TOKEN: OAuth access token (alternative)"
echo "- P8_USER_EMAIL: User email address"