#!/usr/bin/env python3
"""Test TUS authentication flow"""

import os
import requests
import uuid
import base64

# Set up environment
os.environ['P8_PG_HOST'] = 'eepis.percolationlabs.ai'
os.environ['P8_PG_PORT'] = '5434'
os.environ['P8_PG_PASSWORD'] = os.environ.get('P8_TEST_BEARER_TOKEN')

# Test parameters
BEARER_TOKEN = "p8-HsByeefq3unTFJDuf6cRh6GDQpo3laj0AMoyc2Etfqma6Coz73TdBPDfek_LQIMv"
USER_EMAIL = "amartey@gmail.com"
API_BASE = "http://localhost:8002"  # Adjust if needed

def test_get_user_id():
    """Test the get_user_id dependency directly"""
    import sys
    sys.path.insert(0, '/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate')
    
    from fastapi import Request
    from fastapi.security import HTTPAuthorizationCredentials
    from percolate.api.routes.auth import get_user_id, get_api_key
    import asyncio
    
    # Create mock request
    class MockRequest:
        def __init__(self):
            self.cookies = {}
            self.headers = {
                'authorization': f'Bearer {BEARER_TOKEN}',
                'x-user-email': USER_EMAIL
            }
            self.query_params = {}
    
    # Create auth credentials
    auth = HTTPAuthorizationCredentials(scheme="Bearer", credentials=BEARER_TOKEN)
    request = MockRequest()
    
    async def test():
        try:
            # Test bearer token validation
            print("Testing bearer token validation...")
            token = await get_api_key(auth)
            print(f"Bearer token valid: {bool(token)}")
            
            # Test get_user_id
            print("\nTesting get_user_id...")
            user_id = await get_user_id(request, auth)
            print(f"User ID returned: {user_id}")
            
        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()
    
    asyncio.run(test())

def test_tus_create():
    """Test TUS upload creation with auth headers"""
    
    # Prepare test file metadata
    filename = "test_auth.txt"
    file_size = 100
    
    # Encode metadata (TUS format)
    metadata = base64.b64encode(f"filename {base64.b64encode(filename.encode()).decode()}".encode()).decode()
    
    headers = {
        "Authorization": f"Bearer {BEARER_TOKEN}",
        "X-User-Email": USER_EMAIL,
        "Tus-Resumable": "1.0.0",
        "Upload-Length": str(file_size),
        "Upload-Metadata": metadata
    }
    
    print(f"\nTesting TUS upload creation...")
    print(f"Headers: {headers}")
    
    try:
        response = requests.post(f"{API_BASE}/tus/", headers=headers)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.text}")
        
        if response.status_code == 201:
            location = response.headers.get('Location')
            print(f"Upload created at: {location}")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    print("=== Testing Authentication Flow ===")
    test_get_user_id()
    # test_tus_create()  # Uncomment to test actual API call