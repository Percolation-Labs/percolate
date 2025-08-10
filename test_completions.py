#!/usr/bin/env python3
"""
Test completions endpoint to ensure it works without errors
"""

import requests
import json
import os

def test_completions_endpoint():
    """Test the completions endpoint"""
    
    # Get environment variables
    api_endpoint = os.getenv("P8_API_ENDPOINT", "https://p8.resmagic.io")
    api_key = os.getenv("P8_TEST_BEARER_TOKEN", "")
    
    if not api_key:
        print("Error: P8_TEST_BEARER_TOKEN environment variable not set")
        return False
        
    # Test URL
    completions_url = f"{api_endpoint}/v1/agents/p8-UserRoleAgent/chat/completions"
    
    # Test payload
    payload = {
        "model": "gpt-4o-mini",
        "messages": [
            {
                "role": "user", 
                "content": "What is 2+2? Please respond briefly."
            }
        ],
        "max_tokens": 50,
        "stream": False
    }
    
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "X-User-Email": "test@example.com"
    }
    
    print(f"Testing completions endpoint: {completions_url}")
    print(f"Using API key: {api_key[:10]}...")
    print(f"Headers: {headers}")
    
    try:
        response = requests.post(completions_url, json=payload, headers=headers, timeout=30)
        
        print(f"Response status: {response.status_code}")
        print(f"Response headers: {dict(response.headers)}")
        
        if response.status_code == 200:
            try:
                result = response.json()
                print("✅ Success! Response JSON:")
                print(json.dumps(result, indent=2))
                
                # Check for expected structure
                if 'choices' in result and len(result['choices']) > 0:
                    content = result['choices'][0].get('message', {}).get('content', '')
                    if content:
                        print(f"✅ Got content response: {content[:100]}...")
                        return True
                    else:
                        print("❌ No content in response")
                        return False
                else:
                    print("❌ No choices in response")
                    return False
                    
            except json.JSONDecodeError as e:
                print(f"❌ Failed to parse JSON response: {e}")
                print(f"Raw response: {response.text}")
                return False
                
        else:
            print(f"❌ Request failed with status {response.status_code}")
            try:
                error_data = response.json()
                print(f"Error response: {json.dumps(error_data, indent=2)}")
            except:
                print(f"Raw error response: {response.text}")
            return False
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Request failed: {e}")
        return False

if __name__ == "__main__":
    success = test_completions_endpoint()
    print(f"\nTest result: {'PASSED' if success else 'FAILED'}")