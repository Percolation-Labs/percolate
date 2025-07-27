#!/usr/bin/env python3
"""
Script to refactor authentication code from percolate.auth to percolate.api.auth
"""

import os
import re
import shutil
from pathlib import Path

# Base directory
BASE_DIR = Path(__file__).parent

# Source and destination
SRC_DIR = BASE_DIR / "percolate" / "auth"
DEST_DIR = BASE_DIR / "percolate" / "api" / "auth"

# Files that need import updates
FILES_TO_UPDATE = [
    "percolate/api/main.py",
    "percolate/api/routes/auth/oauth.py",
    "percolate/api/routes/auth/router.py",
    "percolate/api/routes/auth/__init__.py",
    "percolate/api/mcp_server/auth.py",
    "test_percolate/integration/api/test_oauth.py",
    "test_percolate/integration/auth/test_all_auth_modes.py",
    "test_percolate/integration/auth/test_mode_a_bearer_auth.py",
    "test_percolate/integration/auth/test_mode_b_oauth_relay.py",
]

# Import patterns to replace
IMPORT_PATTERNS = [
    (r'from percolate\.auth\.', 'from percolate.api.auth.'),
    (r'from percolate\.auth import', 'from percolate.api.auth import'),
    (r'import percolate\.auth\.', 'import percolate.api.auth.'),
]


def update_imports_in_file(filepath):
    """Update import statements in a file"""
    filepath = BASE_DIR / filepath
    if not filepath.exists():
        print(f"  ⚠️  File not found: {filepath}")
        return
    
    content = filepath.read_text()
    original_content = content
    
    for pattern, replacement in IMPORT_PATTERNS:
        content = re.sub(pattern, replacement, content)
    
    if content != original_content:
        filepath.write_text(content)
        print(f"  ✓ Updated imports in {filepath.name}")
    else:
        print(f"  - No changes needed in {filepath.name}")


def move_auth_directory():
    """Move auth directory to api/auth"""
    print("\n1. Moving auth directory...")
    
    if not SRC_DIR.exists():
        print(f"  ❌ Source directory not found: {SRC_DIR}")
        return False
    
    # Create destination if it doesn't exist
    DEST_DIR.parent.mkdir(exist_ok=True)
    
    # Remove destination if it exists
    if DEST_DIR.exists():
        shutil.rmtree(DEST_DIR)
    
    # Move the directory
    shutil.move(str(SRC_DIR), str(DEST_DIR))
    print(f"  ✓ Moved {SRC_DIR} -> {DEST_DIR}")
    
    return True


def update_all_imports():
    """Update all import statements"""
    print("\n2. Updating import statements...")
    
    # Update listed files
    for filepath in FILES_TO_UPDATE:
        update_imports_in_file(filepath)
    
    # Find and update any other Python files with auth imports
    print("\n3. Searching for other files with auth imports...")
    
    for py_file in BASE_DIR.rglob("*.py"):
        # Skip the auth directory itself and this script
        if "percolate/api/auth" in str(py_file) or py_file.name == "refactor_auth_to_api.py":
            continue
        
        try:
            content = py_file.read_text()
            if "percolate.auth" in content or "from percolate.auth" in content:
                # Get relative path for display
                rel_path = py_file.relative_to(BASE_DIR)
                print(f"\n  Found auth imports in: {rel_path}")
                update_imports_in_file(rel_path)
        except Exception as e:
            pass  # Skip files we can't read


def update_auth_internal_imports():
    """Update imports within the auth module itself"""
    print("\n4. Updating internal imports in auth module...")
    
    auth_files = list(DEST_DIR.glob("*.py"))
    
    for py_file in auth_files:
        content = py_file.read_text()
        original_content = content
        
        # Update relative imports that might reference other auth modules
        # Example: from ..auth.models -> from .models (since we're now in api.auth)
        content = re.sub(r'from \.\.auth\.', 'from .', content)
        
        # Update absolute imports within auth files
        for pattern, replacement in IMPORT_PATTERNS:
            content = re.sub(pattern, replacement, content)
        
        if content != original_content:
            py_file.write_text(content)
            print(f"  ✓ Updated internal imports in {py_file.name}")


def main():
    """Run the refactoring"""
    print("Authentication Refactoring Script")
    print("=" * 50)
    print(f"Moving: {SRC_DIR}")
    print(f"To:     {DEST_DIR}")
    print("=" * 50)
    
    # Move directory
    if not move_auth_directory():
        print("\n❌ Failed to move directory. Aborting.")
        return
    
    # Update imports
    update_all_imports()
    
    # Update internal imports
    update_auth_internal_imports()
    
    print("\n" + "=" * 50)
    print("✅ Refactoring complete!")
    print("\nNext steps:")
    print("1. Run tests to ensure everything works")
    print("2. Restart the API server")
    print("3. Update any documentation that references the old import paths")


if __name__ == "__main__":
    main()