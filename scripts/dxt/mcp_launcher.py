#!/usr/bin/env python3
"""Launcher for Percolate MCP Server with platform-specific dependency loading"""
import sys
import os
import platform
import sysconfig

def get_platform_tag():
    """Get the platform-specific tag for loading correct binaries"""
    system = platform.system().lower()
    machine = platform.machine().lower()
    
    if system == 'darwin':
        # macOS
        if machine == 'arm64':
            return 'macosx_11_0_arm64'
        else:
            return 'macosx_10_9_x86_64'
    elif system == 'windows':
        return 'win_amd64'
    elif system == 'linux':
        if machine == 'aarch64':
            return 'manylinux2014_aarch64'
        else:
            return 'manylinux2014_x86_64'
    else:
        return None

# CRITICAL: Add lib directory FIRST for bundled dependencies
lib_path = os.path.join(os.path.dirname(__file__), 'build', 'lib')
if os.path.exists(lib_path):
    sys.path.insert(0, lib_path)
    platform_tag = get_platform_tag()
    print(f"Added bundled dependencies from: {lib_path}", file=sys.stderr)
    print(f"Platform detected: {platform.system()} {platform.machine()} -> {platform_tag}", file=sys.stderr)
    
    # Import the wheel loader to trigger extraction
    try:
        import sys
        sys.path.insert(0, lib_path)
        from . import __init__ as lib_init
        print("Wheel extraction triggered", file=sys.stderr)
    except Exception as e:
        print(f"Failed to trigger wheel extraction: {e}", file=sys.stderr)
        # Manually trigger wheel extraction
        try:
            with open(os.path.join(lib_path, '__init__.py'), 'r') as f:
                code = f.read()
            exec(code, {'__file__': os.path.join(lib_path, '__init__.py')})
            print("Manual wheel extraction completed", file=sys.stderr)
        except Exception as e2:
            print(f"Manual extraction also failed: {e2}", file=sys.stderr)

# Then add build directory for our code
build_path = os.path.join(os.path.dirname(__file__), 'build')
if os.path.exists(build_path):
    sys.path.insert(0, build_path)
else:
    # For testing directly in scripts/dxt
    sys.path.insert(0, os.path.dirname(__file__))

def check_critical_deps():
    """Check only the most critical dependencies"""
    try:
        import fastmcp
        import pydantic
        import httpx
        return True
    except ImportError as e:
        print(f"❌ Missing critical dependency: {e}", file=sys.stderr)
        print(f"Python path: {sys.path}", file=sys.stderr)
        print(f"Lib directory exists: {os.path.exists(lib_path)}", file=sys.stderr)
        if os.path.exists(lib_path):
            print(f"Lib directory contents: {os.listdir(lib_path)[:10]}", file=sys.stderr)
        return False

if __name__ == "__main__":
    if not check_critical_deps():
        sys.exit(1)
    
    # Debug: Log environment variables
    import os
    print("=== Environment Variables ===", file=sys.stderr)
    for key in sorted(os.environ.keys()):
        if key.startswith('P8_') or key in ['PYTHONPATH', 'X_User_Email']:
            value = os.environ.get(key, '')
            if 'TOKEN' in key or 'KEY' in key:
                print(f"{key}: {'SET' if value else 'NOT SET'}", file=sys.stderr)
            else:
                print(f"{key}: {value}", file=sys.stderr)
    print("===========================", file=sys.stderr)
    
    # Import and run the MCP server
    from mcp_server.server import run_stdio
    run_stdio()