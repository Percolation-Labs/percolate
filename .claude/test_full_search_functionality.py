#!/usr/bin/env python3
"""Test full user upload search functionality."""

import requests
import json

# Create session with the provided cookie
session = requests.Session()
session.cookies.set('session', 'eyJzeW5jX2ZpbGVzIjogZmFsc2UsICJ0b2tlbiI6IHsiYWNjZXNzX3Rva2VuIjogInlhMjkuYTBBVzRYdHhocFU5Q1ZwU284R2FwR0JQaHZYcHA0S1BJdGREbW9ocmc3ZFNBbllXdEN4ajM3N2pRcTA1Sk03UnhsR3phSk05cWNkU09SWk5rdjlxckdNV1NfUkVqRFhGMVU1Z3FtN0ZDbEhUb3RUM1N3SldyUmJCZGd3d2N2SWlKbWZmSzZDSWZDemdYNHdJZTQ0ZDFlVFV2emkzc1Y4Z2FTTkstX2tENDVhQ2dZS0FXUVNBUmNTRlFIR1gyTWlHLXRJNXlmYzBFTTA5MnFTMnN6aFpnMDE3NSIsICJleHBpcmVzX2luIjogMzU5OSwgInJlZnJlc2hfdG9rZW4iOiAiMS8vMDVZWDNsZG04WXVJeUNnWUlBUkFBR0FVU053Ri1MOUlyYW1wNHlKR2Y5TnA0UW9aUlVGYkdQeVJXaTlWRHZUX0VLdVJ0cFJ3YnJUcHYxS1FVY1VtOFlBV1hQWURBNnhkckc0TSIsICJzY29wZSI6ICJodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL2RyaXZlLnJlYWRvbmx5IGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvdXNlcmluZm8ucHJvZmlsZSBodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL3VzZXJpbmZvLmVtYWlsIGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvZG9jdW1lbnRzLnJlYWRvbmx5IGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvZ21haWwucmVhZG9ubHkgb3BlbmlkIiwgInRva2VuX3R5cGUiOiAiQmVhcmVyIiwgImlkX3Rva2VuIjogImV5SmhiR2NpT2lKU1V6STFOaUlzSW10cFpDSTZJalkyTUdWbU0ySTVOemcwWW1SbU5UWmxZbVU0TlRsbU5UYzNaamRtWWpKbE9HTXhZMlZtWm1JaUxDSjBlWEFpT2lKS1YxUWlmUS5leUpwYzNNaU9pSm9kSFJ3Y3pvdkwyRmpZMjkxYm5SekxtZHZiMmRzWlM1amIyMGlMQ0poZW5BaU9pSXhNRGs1TWpNM09EazBPVE0xTFhBemJqZG5hMncyY3prM2FHb3lNRGh1YjNGdE5ISm9PSEpyTTJkaVluWjBMbUZ3Y0hNdVoyOXZaMnhsZFhObGNtTnZiblJsYm5RdVkyOXRJaXdpWVhWa0lqb2lNVEE1T1RJek56ZzVORGt6TlMxd00yNDNaMnRzTm5NNU4yaHFNakE0Ym05eGJUUnlhRGh5YXpOblltSjJkQzVoY0hCekxtZHZiMmRzWlhWelpYSmpiMjUwWlc1MExtTnZiU0lzSW5OMVlpSTZJakV3TWpFMk5UUTNOakV4TkRnd05EQTVOakl6TUNJc0ltVnRZV2xzSWpvaVlXMWhjblJsZVVCbmJXRnBiQzVqYjIwaUxDSmxiV0ZwYkY5MlpYSnBabWxsWkNJNmRISjFaU3dpWVhSZmFHRnphQ0k2SW5OclYyWktjbTVsTlRaMmEyaFRMVnBKVEhOSlNXY2lMQ0p1YjI1alpTSTZJbkp2WlRNM1UzWkJjbmMyU0VwSVVsQTFTbTl0SWl3aWJtRnRaU0k2SWxOaGIybHljMlVnUVcxaGNuUmxhV1pwYnlJc0luQnBZM1IxY21VaU9pSm9kSFJ3Y3pvdkwyeG9NeTVuYjI5bmJHVjFjMlZ5WTI5dWRHVnVkQzVqYjIwdllTOUJRMmM0YjJOTWFWbFFNM0J0TFhSNmFITldURkp1T1ZoaVoxQlFWa2g0U0RCYWVUQmpSMmROZERKcVlVVkJZMnR3VDBsdlRGUkVaejF6T1RZdFl5SXNJbWRwZG1WdVgyNWhiV1VpT2lKVFlXOXBjbk5sSWl3aVptRnRhV3g1WDI1aGJXVWlPaUpCYldGeWRHVnBabWx2SWl3aWFXRjBJam94TnpRM05EQTJPVGszTENKbGVIQWlPakUzTkRjME1UQTFPVGQ5LmM5NWQ5WGtWREFQcjdjU3hBUWVtZzFYWXROSjREcHJhS2JIYlUwb0t1VmNlcDdybTNxQnRqOTZ4c0VnSWc5SXBWVlQ5Ym4zTDF2alU5OTYyVDdQeC1BWEdNYzRab25YX3FYTGc2M1pueGhBVHNIcXdoQ2VoS2N5NVZxYkxkbVVtYnlsZmFYR0pIbFp5ZDhRbkU1RVppY3B1d3ZhN1U5Y3F2Q184ZTVERkN6Ymk5d0V2bHNmc21Vb3U3U0dWdERkX2dqVUxfNTY4RldhSktrNmt3aUhBZXRUaEQ5WmZUaGgybE1vZHdrVHhuOXVzTWhNZ2oyeENvLXR4bjdqa3hRNnk1NGpINE1DRnhUZzk4V2lRdFJvWkxUbm9neXVYbGZzVkI3V3FQdllqTjlrR2tmMnU3SzJCOHFuMkJGT1NjTFJPaHRGSzJDcTIzVm1WZzhNMmVXQlB6dyIsICJyZWZyZXNoX3Rva2VuX2V4cGlyZXNfaW4iOiA2MDQ3OTksICJleHBpcmVzX2F0IjogMTc0NzQxMDU5NiwgInVzZXJpbmZvIjogeyJpc3MiOiAiaHR0cHM6Ly9hY2NvdW50cy5nb29nbGUuY29tIiwgImF6cCI6ICIxMDk5MjM3ODk0OTM1LXAzbjdna2w2czk3aGoyMDhub3FtNHJoOHJrM2diYnZ0LmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29tIiwgImF1ZCI6ICIxMDk5MjM3ODk0OTM1LXAzbjdna2w2czk3aGoyMDhub3FtNHJoOHJrM2diYnZ0LmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29tIiwgInN1YiI6ICIxMDIxNjU0NzYxMTQ4MDQwOTYyMzAiLCAiZW1haWwiOiAiYW1hcnRleUBnbWFpbC5jb20iLCAiZW1haWxfdmVyaWZpZWQiOiB0cnVlLCAiYXRfaGFzaCI6ICJza1dmSnJuZTU2dmtoUy1aSUxzSUlnIiwgIm5vbmNlIjogInJvZTM3U3ZBcnc2SEpIUlA1Sm9tIiwgIm5hbWUiOiAiU2FvaXJzZSBBbWFydGVpZmlvIiwgInBpY3R1cmUiOiAiaHR0cHM6Ly9saDMuZ29vZ2xldXNlcmNvbnRlbnQuY29tL2EvQUNnOG9jTGlZUDNwbS10emhzVkxSbjlYYmdQUFZIeEgwWnkwY0dnTXQyamFFQWNrcE9Jb0xURGc9czk2LWMiLCAiZ2l2ZW5fbmFtZSI6ICJTYW9pcnNlIiwgImZhbWlseV9uYW1lIjogIkFtYXJ0ZWlmaW8iLCAiaWF0IjogMTc0NzQwNjk5NywgImV4cCI6IDE3NDc0MTA1OTd9fSwgInNlc3Npb25faWQiOiAiYzU4ZmQ1MWYtNDAzZC00MjU3LTllMTgtMTc3MzdlNDRmZDNmIn0=.aCdQlQ.qHKMWsxfHuBLHnk3Ck3Ux_tiqp8')

base_url = 'http://localhost:5008'

def test_no_params():
    """Test with no parameters - should return most recent uploads."""
    print("Test 1: No parameters (most recent uploads)")
    print("="*50)
    
    response = session.get(f'{base_url}/tus/user/uploads')
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ Success: {len(data)} uploads returned")
        
        if data:
            print("\nMost recent uploads:")
            for i, upload in enumerate(data[:3]):
                print(f"\n{i+1}. {upload['filename']}")
                print(f"   Created: {upload['created_at']}")
                print(f"   Size: {upload['total_size']:,} bytes")
                print(f"   Status: {upload['status']}")
                if upload.get('tags'):
                    print(f"   Tags: {upload['tags']}")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def test_with_tags():
    """Test filtering by tags."""
    print("\n\nTest 2: Filter by tags")
    print("="*50)
    
    # POST request with tags filter
    request_data = {
        "tags": ["test", "document"],
        "limit": 10
    }
    
    response = session.post(f'{base_url}/tus/user/uploads/search', json=request_data)
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ Success: {len(data)} uploads with matching tags")
        
        if data:
            print("\nUploads with tags:")
            for i, upload in enumerate(data[:3]):
                print(f"\n{i+1}. {upload['filename']}")
                print(f"   Tags: {upload.get('tags', [])}")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def test_semantic_search():
    """Test semantic search - might fail if embeddings not available."""
    print("\n\nTest 3: Semantic search")
    print("="*50)
    
    # POST request with semantic query
    request_data = {
        "query_text": "financial report",
        "limit": 5
    }
    
    print(f"Searching for: '{request_data['query_text']}'")
    
    response = session.post(f'{base_url}/tus/user/uploads/search', json=request_data)
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ Success: {len(data)} results")
        
        if data:
            print("\nSearch results:")
            for i, upload in enumerate(data):
                print(f"\n{i+1}. {upload['filename']}")
                if upload.get('semantic_score'):
                    print(f"   Score: {upload['semantic_score']:.4f}")
                if upload.get('resource_name'):
                    print(f"   Resource: {upload['resource_name']}")
                if upload.get('chunk_count'):
                    print(f"   Chunks: {upload['chunk_count']}")
        else:
            print("No results found")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def test_combined_search():
    """Test combined semantic search with tags."""
    print("\n\nTest 4: Combined search (semantic + tags)")
    print("="*50)
    
    request_data = {
        "query_text": "test",
        "tags": ["document"],
        "limit": 5
    }
    
    print(f"Searching for: '{request_data['query_text']}' with tags {request_data['tags']}")
    
    response = session.post(f'{base_url}/tus/user/uploads/search', json=request_data)
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ Success: {len(data)} results")
        
        if data:
            print("\nSearch results:")
            for i, upload in enumerate(data):
                print(f"\n{i+1}. {upload['filename']}")
                print(f"   Tags: {upload.get('tags', [])}")
                if upload.get('semantic_score'):
                    print(f"   Score: {upload['semantic_score']:.4f}")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def test_get_endpoint():
    """Test GET endpoint with query parameters."""
    print("\n\nTest 5: GET endpoint with query parameters")
    print("="*50)
    
    params = {
        'tags': ['test'],
        'limit': 3
    }
    
    response = session.get(f'{base_url}/tus/user/uploads', params=params)
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ Success: {len(data)} results")
        
        if data:
            print("\nResults:")
            for i, upload in enumerate(data):
                print(f"\n{i+1}. {upload['filename']}")
                print(f"   Tags: {upload.get('tags', [])}")
    else:
        print(f"❌ Error {response.status_code}: {response.text}")

def main():
    """Run all tests."""
    print("User Upload Search Functionality Tests")
    print("="*60)
    
    test_no_params()
    test_with_tags()
    test_semantic_search()
    test_combined_search()
    test_get_endpoint()
    
    print("\n\n" + "="*60)
    print("All tests completed!")
    print("="*60)

if __name__ == "__main__":
    main()