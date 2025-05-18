#!/usr/bin/env python3

import re
import sys
from pathlib import Path

def update_test_file(file_path):
    print(f"Updating {file_path}")
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Replace imports
    content = re.sub(
        r'from percolate\.api\.routes\.auth import hybrid_auth',
        'from percolate.api.routes.admin.router import optional_hybrid_auth',
        content
    )
    
    # Replace dependency overrides
    content = re.sub(
        r'app\.dependency_overrides\[hybrid_auth\]',
        'app.dependency_overrides[optional_hybrid_auth]',
        content
    )
    
    # Replace function names
    content = re.sub(
        r'def override_hybrid_auth\(\):',
        'def override_optional_hybrid_auth():',
        content
    )
    
    content = re.sub(
        r'override_hybrid_auth',
        'override_optional_hybrid_auth',
        content
    )
    
    with open(file_path, 'w') as f:
        f.write(content)
    print(f"Updated {file_path}")

# Update all test files
test_dir = Path('/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/test_percolate/api/routes')
test_files = list(test_dir.glob('test_admin_content_upload*.py'))

for test_file in test_files:
    try:
        update_test_file(test_file)
    except Exception as e:
        print(f"Error updating {test_file}: {e}")

print("All test files updated")