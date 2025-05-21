#!/usr/bin/env python3
"""Test the user upload search endpoint with real session authentication."""

import requests
import json
from datetime import datetime

# Create session with the provided cookie
session = requests.Session()
session.cookies.set('session', 'eyJzeW5jX2ZpbGVzIjogZmFsc2UsICJ0b2tlbiI6IHsiYWNjZXNzX3Rva2VuIjogInlhMjkuYTBBVzRYdHhocFU5Q1ZwU284R2FwR0JQaHZYcHA0S1BJdGREbW9ocmc3ZFNBbllXdEN4ajM3N2pRcTA1Sk03UnhsR3phSk05cWNkU09SWk5rdjlxckdNV1NfUkVqRFhGMVU1Z3FtN0ZDbEhUb3RUM1N3SldyUmJCZGd3d2N2SWlKbWZmSzZDSWZDemdYNHdJZTQ0ZDFlVFV2emkzc1Y4Z2FTTkstX2tENDVhQ2dZS0FXUVNBUmNTRlFIR1gyTWlHLXRJNXlmYzBFTTA5MnFTMnN6aFpnMDE3NSIsICJleHBpcmVzX2luIjogMzU5OSwgInJlZnJlc2hfdG9rZW4iOiAiMS8vMDVZWDNsZG04WXVJeUNnWUlBUkFBR0FVU053Ri1MOUlyYW1wNHlKR2Y5TnA0UW9aUlVGYkdQeVJXaTlWRHZUX0VLdVJ0cFJ3YnJUcHYxS1FVY1VtOFlBV1hQWURBNnhkckc0TSIsICJzY29wZSI6ICJodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL2RyaXZlLnJlYWRvbmx5IGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvdXNlcmluZm8ucHJvZmlsZSBodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL3VzZXJpbmZvLmVtYWlsIGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvZG9jdW1lbnRzLnJlYWRvbmx5IGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvZ21haWwucmVhZG9ubHkgb3BlbmlkIiwgInRva2VuX3R5cGUiOiAiQmVhcmVyIiwgImlkX3Rva2VuIjogImV5SmhiR2NpT2lKU1V6STFOaUlzSW10cFpDSTZJalkyTUdWbU0ySTVOemcwWW1SbU5UWmxZbVU0TlRsbU5UYzNaamRtWWpKbE9HTXhZMlZtWm1JaUxDSjBlWEFpT2lKS1YxUWlmUS5leUpwYzNNaU9pSm9kSFJ3Y3pvdkwyRmpZMjkxYm5SekxtZHZiMmRzWlM1amIyMGlMQ0poZW5BaU9pSXhNRGs1TWpNM09EazBPVE0xTFhBemJqZG5hMncyY3prM2FHb3lNRGh1YjNGdE5ISm9PSEpyTTJkaVluWjBMbUZ3Y0hNdVoyOXZaMnhsZFhObGNtTnZiblJsYm5RdVkyOXRJaXdpWVhWa0lqb2lNVEE1T1RJek56ZzVORGt6TlMxd00yNDNaMnRzTm5NNU4yaHFNakE0Ym05eGJUUnlhRGh5YXpOblltSjJkQzVoY0hCekxtZHZiMmRzWlhWelpYSmpiMjUwWlc1MExtTnZiU0lzSW5OMVlpSTZJakV3TWpFMk5UUTNOakV4TkRnd05EQTVOakl6TUNJc0ltVnRZV2xzSWpvaVlXMWhjblJsZVVCbmJXRnBiQzVqYjIwaUxDSmxiV0ZwYkY5MlpYSnBabWxsWkNJNmRISjFaU3dpWVhSZmFHRnphQ0k2SW5OclYyWktjbTVsTlRaMmEyaFRMVnBKVEhOSlNXY2lMQ0p1YjI1alpTSTZJbkp2WlRNM1UzWkJjbmMyU0VwSVVsQTFTbTl0SWl3aWJtRnRaU0k2SWxOaGIybHljMlVnUVcxaGNuUmxhV1pwYnlJc0luQnBZM1IxY21VaU9pSm9kSFJ3Y3pvdkwyeG9NeTVuYjI5bmJHVjFjMlZ5WTI5dWRHVnVkQzVqYjIwdllTOUJRMmM0YjJOTWFWbFFNM0J0TFhSNmFITldURkp1T1ZoaVoxQlFWa2g0U0RCYWVUQmpSMmROZERKcVlVVkJZMnR3VDBsdlRGUkVaejF6T1RZdFl5SXNJbWRwZG1WdVgyNWhiV1VpT2lKVFlXOXBjbk5sSWl3aVptRnRhV3g1WDI1aGJXVWlPaUpCYldGeWRHVnBabWx2SWl3aWFXRjBJam94TnpRM05EQTJPVGszTENKbGVIQWlPakUzTkRjME1UQTFPVGQ5LmM5NWQ5WGtWREFQcjdjU3hBUWVtZzFYWXROSjREcHJhS2JIYlUwb0t1VmNlcDdybTNxQnRqOTZ4c0VnSWc5SXBWVlQ5Ym4zTDF2alU5OTYyVDdQeC1BWEdNYzRab25YX3FYTGc2M1pueGhBVHNIcXdoQ2VoS2N5NVZxYkxkbVVtYnlsZmFYR0pIbFp5ZDhRbkU1RVppY3B1d3ZhN1U5Y3F2Q184ZTVERkN6Ymk5d0V2bHNmc21Vb3U3U0dWdERkX2dqVUxfNTY4RldhSktrNmt3aUhBZXRUaEQ5WmZUaGgybE1vZHdrVHhuOXVzTWhNZ2oyeENvLXR4bjdqa3hRNnk1NGpINE1DRnhUZzk4V2lRdFJvWkxUbm9neXVYbGZzVkI3V3FQdllqTjlrR2tmMnU3SzJCOHFuMkJGT1NjTFJPaHRGSzJDcTIzVm1WZzhNMmVXQlB6dyIsICJyZWZyZXNoX3Rva2VuX2V4cGlyZXNfaW4iOiA2MDQ3OTksICJleHBpcmVzX2F0IjogMTc0NzQxMDU5NiwgInVzZXJpbmZvIjogeyJpc3MiOiAiaHR0cHM6Ly9hY2NvdW50cy5nb29nbGUuY29tIiwgImF6cCI6ICIxMDk5MjM3ODk0OTM1LXAzbjdna2w2czk3aGoyMDhub3FtNHJoOHJrM2diYnZ0LmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29tIiwgImF1ZCI6ICIxMDk5MjM3ODk0OTM1LXAzbjdna2w2czk3aGoyMDhub3FtNHJoOHJrM2diYnZ0LmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29tIiwgInN1YiI6ICIxMDIxNjU0NzYxMTQ4MDQwOTYyMzAiLCAiZW1haWwiOiAiYW1hcnRleUBnbWFpbC5jb20iLCAiZW1haWxfdmVyaWZpZWQiOiB0cnVlLCAiYXRfaGFzaCI6ICJza1dmSnJuZTU2dmtoUy1aSUxzSUlnIiwgIm5vbmNlIjogInJvZTM3U3ZBcnc2SEpIUlA1Sm9tIiwgIm5hbWUiOiAiU2FvaXJzZSBBbWFydGVpZmlvIiwgInBpY3R1cmUiOiAiaHR0cHM6Ly9saDMuZ29vZ2xldXNlcmNvbnRlbnQuY29tL2EvQUNnOG9jTGlZUDNwbS10emhzVkxSbjlYYmdQUFZIeEgwWnkwY0dnTXQyamFFQWNrcE9Jb0xURGc9czk2LWMiLCAiZ2l2ZW5fbmFtZSI6ICJTYW9pcnNlIiwgImZhbWlseV9uYW1lIjogIkFtYXJ0ZWlmaW8iLCAiaWF0IjogMTc0NzQwNjk5NywgImV4cCI6IDE3NDc0MTA1OTd9fSwgInNlc3Npb25faWQiOiAiYzU4ZmQ1MWYtNDAzZC00MjU3LTllMTgtMTc3MzdlNDRmZDNmIn0=.aCdQlQ.qHKMWsxfHuBLHnk3Ck3Ux_tiqp8')

base_url = 'http://localhost:5008'

def test_auth():
    """Test authentication works."""
    print("Testing authentication...")
    
    # Test ping
    response = session.get(f'{base_url}/auth/ping')
    print(f"Ping response: {response.json()}")
    
    # Test session info
    response = session.get(f'{base_url}/auth/session/info')
    session_info = response.json()
    print(f"Session info: {json.dumps(session_info, indent=2)}")
    
    # Extract user ID from session
    if 'user_id' in session_info:
        user_id = session_info['user_id']
        print(f"User ID: {user_id}")
        return user_id
    elif 'user_info' in session_info and 'id' in session_info['user_info']:
        user_id = session_info['user_info']['id']
        print(f"User ID: {user_id}")
        return user_id
    else:
        print("Could not extract user ID from session")
        return None

def test_user_uploads_no_params(user_id):
    """Test getting user uploads with no parameters (most recent files)."""
    print("\n" + "="*60)
    print("Test 1: Get recent uploads with no parameters")
    print("="*60)
    
    response = session.get(f'{base_url}/tus/user/uploads')
    
    if response.status_code == 200:
        uploads = response.json()
        print(f"✅ Success - returned {len(uploads)} uploads")
        print("\nRecent uploads:")
        for i, upload in enumerate(uploads[:5]):  # Show first 5
            print(f"\n{i+1}. {upload['filename']}")
            print(f"   Upload ID: {upload['upload_id']}")
            print(f"   Size: {upload['total_size']:,} bytes")
            print(f"   Status: {upload['status']}")
            print(f"   Created: {upload['created_at']}")
            if upload.get('tags'):
                print(f"   Tags: {upload['tags']}")
            if upload.get('semantic_score'):
                print(f"   Semantic Score: {upload['semantic_score']}")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def test_user_uploads_with_tags():
    """Test getting user uploads filtered by tags."""
    print("\n" + "="*60)
    print("Test 2: Get uploads filtered by tags")
    print("="*60)
    
    # Try with common tags
    test_tags = ['test', 'document']
    response = session.get(f'{base_url}/tus/user/uploads', params={'tags': test_tags})
    
    if response.status_code == 200:
        uploads = response.json()
        print(f"✅ Success - returned {len(uploads)} uploads with tags {test_tags}")
        if uploads:
            for i, upload in enumerate(uploads[:3]):
                print(f"\n{i+1}. {upload['filename']}")
                print(f"   Tags: {upload.get('tags', [])}")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def test_semantic_search():
    """Test semantic search functionality."""
    print("\n" + "="*60)
    print("Test 3: Semantic search")
    print("="*60)
    
    # Test queries
    test_queries = [
        "test document",
        "financial report",
        "project documentation"
    ]
    
    for query in test_queries:
        print(f"\nSearching for: '{query}'")
        
        # Use POST endpoint with request body
        search_request = {
            "query_text": query,
            "limit": 5
        }
        
        response = session.post(f'{base_url}/tus/user/uploads/search', json=search_request)
        
        if response.status_code == 200:
            uploads = response.json()
            print(f"✅ Success - returned {len(uploads)} results")
            
            if uploads:
                for i, upload in enumerate(uploads[:3]):
                    print(f"\n  {i+1}. {upload['filename']}")
                    if upload.get('semantic_score'):
                        print(f"     Score: {upload['semantic_score']:.4f}")
                    if upload.get('resource_name'):
                        print(f"     Resource: {upload['resource_name']}")
                    if upload.get('chunk_count'):
                        print(f"     Chunks: {upload['chunk_count']}")
        else:
            print(f"❌ Error {response.status_code}: {response.text}")

def test_combined_search():
    """Test combined semantic search with tags."""
    print("\n" + "="*60)
    print("Test 4: Combined semantic search with tags")
    print("="*60)
    
    search_request = {
        "query_text": "test",
        "tags": ["document"],
        "limit": 5
    }
    
    print(f"Searching with query '{search_request['query_text']}' and tags {search_request['tags']}")
    
    response = session.post(f'{base_url}/tus/user/uploads/search', json=search_request)
    
    if response.status_code == 200:
        uploads = response.json()
        print(f"✅ Success - returned {len(uploads)} results")
        
        if uploads:
            for i, upload in enumerate(uploads):
                print(f"\n{i+1}. {upload['filename']}")
                print(f"   Tags: {upload.get('tags', [])}")
                if upload.get('semantic_score'):
                    print(f"   Score: {upload['semantic_score']:.4f}")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def main():
    """Run all tests."""
    print("Testing User Upload Search Endpoints")
    print("="*40)
    
    # Test authentication and get user ID
    user_id = test_auth()
    if not user_id:
        print("Authentication failed, cannot continue tests")
        return
    
    # Run tests
    test_user_uploads_no_params(user_id)
    test_user_uploads_with_tags()
    test_semantic_search()
    test_combined_search()
    
    print("\n" + "="*60)
    print("All tests completed")
    print("="*60)

if __name__ == "__main__":
    main()