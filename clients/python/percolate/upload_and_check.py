#!/usr/bin/env python3
"""
Upload PDF and check last 5 resources in database
"""
import requests
import os
import time
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import percolate as p8
from percolate.models.p8.types import Resources

# Configuration
API_URL = "http://localhost:5008"
PDF_PATH = "/Users/sirsh/Downloads/test_parsing.pdf"
BEARER_TOKEN = os.environ.get("P8_TEST_BEARER_TOKEN", "p8-HsByeefq3unTFJDuf6cRh6GDQpo3laj0AMoyc2Etfqma6Coz73TdBPDfek_LQIMv")

print("Upload PDF and Check Resources")
print("=" * 80)

# Step 1: Upload the PDF
timestamp = int(time.time())
test_user = f"test_user_{timestamp}"
task_id = f"task_{timestamp}"

print(f"\n1. Uploading PDF: {PDF_PATH}")
print(f"   User: {test_user}")
print(f"   Task: {task_id}")

skip_wait = False

try:
    with open(PDF_PATH, 'rb') as f:
        files = {'file': ('test_parsing.pdf', f, 'application/pdf')}
        data = {
            'add_resource': 'true',
            'task_id': task_id,
            'user_id': test_user,
            'namespace': 'p8',
            'entity_name': 'Resources'
        }
        headers = {'Authorization': f'Bearer {BEARER_TOKEN}'}
        
        response = requests.post(
            f"{API_URL}/admin/content/upload",
            files=files,
            data=data,
            headers=headers,
            timeout=30
        )
        
        if response.status_code == 200:
            result = response.json()
            print(f"\n✅ Upload successful!")
            print(f"   S3 Key: {result.get('key')}")
            print(f"   Size: {result.get('size')} bytes")
        else:
            print(f"\n❌ Upload failed: {response.status_code}")
            print(f"   Error: {response.text}")
            skip_wait = True
            
except Exception as e:
    print(f"\n❌ Upload error: {e}")
    print("\n⚠️  Continuing to check database for existing resources...")
    skip_wait = True

# Step 2: Wait for processing (only if upload succeeded)
if not skip_wait:
    print(f"\n2. Waiting 60 seconds for extended mode processing (OCR)...")
    for i in range(60):
        print(f"\r   {i+1}/60 seconds", end='', flush=True)
        time.sleep(1)
    print()
else:
    print("\n2. Skipping wait since upload failed")

# Step 3: Query last 5 resources
print(f"\n3. Querying last 5 uploaded resources...")
print("-" * 80)

try:
    # Get the last 5 resources
    query = """
    SELECT name, created_at, uri, userid, metadata
    FROM p8."Resources"
    ORDER BY created_at DESC
    LIMIT 5
    """
    
    resources = p8.repository(Resources).execute(query)
    
    if resources:
        for idx, r in enumerate(resources, 1):
            name, created_at, uri, userid, metadata = r
            print(f"\nResource {idx}:")
            print(f"  Name: {name}")
            print(f"  Created: {created_at}")
            print(f"  URI: {uri}")
            print(f"  User: {userid}")
            
            # Check if this is from our upload
            if userid == test_user:
                print(f"  ✅ This is from our current upload!")
                if metadata:
                    mode = metadata.get('parsing_mode', 'unknown')
                    print(f"  Parsing mode: {mode}")
                    if mode == 'extended':
                        print(f"  ✅ Used extended mode with OCR!")
    else:
        print("No resources found in database")
        
    # Count resources for our user
    count_query = f"""
    SELECT COUNT(*)
    FROM p8."Resources"
    WHERE userid = '{test_user}'
    """
    
    count_result = p8.repository(Resources).execute(count_query)
    if count_result:
        count = count_result[0][0]
        print(f"\n📊 Total chunks for this upload: {count}")
        if count > 0 and count < 20:
            print(f"   ✅ Good! Less than 20 chunks")
        elif count >= 20:
            print(f"   ⚠️  Warning: {count} chunks (>= 20)")
            
except Exception as e:
    print(f"\n❌ Database error: {e}")
    import traceback
    traceback.print_exc()

print("\n" + "=" * 80)
print("Done!")