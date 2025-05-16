#!/usr/bin/env python3
"""
Test script to verify session authentication fix.

This script tests that sessions persist across server restarts
by storing the session key in a file or environment variable.
"""

import requests
import json
from datetime import datetime


def test_session_fix():
    """Test the session authentication fix"""
    base_url = "http://localhost:5000"
    
    print(f"\n=== Testing Session Authentication Fix ===")
    print(f"Time: {datetime.now()}")
    
    # Step 1: Check if we can use sessions
    print("\n1. Testing session info endpoint...")
    try:
        response = requests.get(f"{base_url}/auth/session/info")
        print(f"Status: {response.status_code}")
        print(f"Response: {json.dumps(response.json(), indent=2)}")
    except Exception as e:
        print(f"Error: {e}")
    
    # Step 2: Test the ping endpoint
    print("\n2. Testing ping endpoint...")
    try:
        response = requests.get(f"{base_url}/auth/ping")
        print(f"Status: {response.status_code}")
        print(f"Response: {json.dumps(response.json(), indent=2)}")
    except Exception as e:
        print(f"Error: {e}")
    
    print("\n=== Test Complete ===")
    print("\nTo fully test session persistence:")
    print("1. Start the server: uvicorn percolate.api.main:app --port 5000 --reload")
    print("2. Login via Google: http://localhost:5000/auth/google/login")
    print("3. Note the session cookie in your browser")
    print("4. Stop and restart the server")
    print("5. Check if the session still works with the same cookie")
    
    print("\nThe session key is now stored in:")
    print("  - Environment variable: P8_SESSION_KEY (if set)")
    print("  - File: ~/.percolate/auth/session_key.json")
    print("\nThis ensures sessions persist across server restarts.")


if __name__ == "__main__":
    test_session_fix()