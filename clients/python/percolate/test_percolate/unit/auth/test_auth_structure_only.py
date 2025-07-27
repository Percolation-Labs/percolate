#!/usr/bin/env python3
"""
Simple test to verify authentication module structure without instantiation.
"""

import os
import sys
import importlib
from datetime import datetime

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def check_module_exists(module_path):
    """Check if a module exists without importing it fully."""
    try:
        spec = importlib.util.find_spec(module_path)
        return spec is not None
    except:
        return False

def main():
    print(f"\n{'=' * 80}")
    print("PERCOLATE AUTHENTICATION STRUCTURE VERIFICATION")
    print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'=' * 80}\n")
    
    # Define expected structure
    auth_modules = [
        ("percolate.api.auth", "Main auth module"),
        ("percolate.api.auth.models", "Auth data models"),
        ("percolate.api.auth.providers", "Auth providers"),
        ("percolate.api.auth.middleware", "Auth middleware"),
        ("percolate.api.auth.server", "OAuth server"),
        ("percolate.api.auth.jwt_provider", "JWT provider"),
    ]
    
    print("Checking authentication module structure:\n")
    
    all_found = True
    for module_path, description in auth_modules:
        exists = check_module_exists(module_path)
        status = "✓" if exists else "✗"
        print(f"{status} {module_path}")
        print(f"  {description}")
        if not exists:
            all_found = False
    
    # Check API routes auth
    print("\nChecking API routes authentication:")
    routes_auth_modules = [
        ("percolate.api.routes.auth", "Auth routes module"),
        ("percolate.api.routes.auth.router", "Auth router"),
        ("percolate.api.routes.auth.oauth", "OAuth endpoints"),
        ("percolate.api.routes.auth.utils", "Auth utilities"),
    ]
    
    for module_path, description in routes_auth_modules:
        exists = check_module_exists(module_path)
        status = "✓" if exists else "✗"
        print(f"{status} {module_path}")
        print(f"  {description}")
        if not exists:
            all_found = False
    
    # Check MCP server auth
    print("\nChecking MCP server authentication:")
    mcp_auth_exists = check_module_exists("percolate.api.mcp_server.auth")
    print(f"{'✓' if mcp_auth_exists else '✗'} percolate.api.mcp_server.auth")
    print(f"  MCP server authentication module")
    
    # Summary
    print(f"\n{'=' * 80}")
    print("SUMMARY")
    print(f"{'=' * 80}")
    
    if all_found and mcp_auth_exists:
        print("\n✓ All authentication modules found!")
        print("\nAuthentication structure includes:")
        print("  - Core auth module with models and providers")
        print("  - OAuth 2.1 server implementation")
        print("  - JWT provider support")
        print("  - ASGI middleware for request auth")
        print("  - API routes for auth endpoints")
        print("  - MCP server authentication integration")
    else:
        print("\n✗ Some authentication modules are missing.")
        print("Please check the structure above.")
    
    print(f"\n{'=' * 80}\n")
    
    # Try to import and list contents of main auth module
    try:
        print("Contents of percolate.api.auth module:")
        import percolate.api.auth as auth_module
        exports = [item for item in dir(auth_module) if not item.startswith('_')]
        for export in sorted(exports):
            print(f"  - {export}")
    except Exception as e:
        print(f"Could not inspect auth module contents: {e}")
    
    return 0 if (all_found and mcp_auth_exists) else 1

if __name__ == "__main__":
    sys.exit(main())