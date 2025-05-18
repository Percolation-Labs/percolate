#!/usr/bin/env python3

import re
import sys
from pathlib import Path

def mark_tests_as_slow():
    """Mark all admin content upload tests as slow."""
    test_dir = Path('/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/test_percolate/api/routes')
    test_files = list(test_dir.glob('test_admin_content_upload*.py'))
    
    for test_file in test_files:
        if test_file.name == 'test_admin_content_upload_simple.py':
            # Skip our simple test file
            continue
            
        print(f"Marking tests as slow in {test_file}")
        with open(test_file, 'r') as f:
            content = f.read()
        
        # Check if already has @pytest.mark.slow
        if '@pytest.mark.slow' in content:
            print(f"  - Already marked as slow")
            continue
        
        # Add @pytest.mark.slow before class definitions
        content = re.sub(
            r'(class\s+Test\w+.*?:)',
            r'@pytest.mark.slow\n\1',
            content
        )
        
        with open(test_file, 'w') as f:
            f.write(content)
        print(f"  - Marked as slow")

if __name__ == '__main__':
    mark_tests_as_slow()
    print("Done marking tests as slow")