#!/usr/bin/env python3
"""Simple test to debug the user upload search endpoint."""

import requests
import json

# Create session with the provided cookie
session = requests.Session()
session.cookies.set('session', 'eyJzeW5jX2ZpbGVzIjogZmFsc2UsICJ0b2tlbiI6IHsiYWNjZXNzX3Rva2VuIjogInlhMjkuYTBBVzRYdHhocFU5Q1ZwU284R2FwR0JQaHZYcHA0S1BJdGREbW9ocmc3ZFNBbllXdEN4ajM3N2pRcTA1Sk03UnhsR3phSk05cWNkU09SWk5rdjlxckdNV1NfUkVqRFhGMVU1Z3FtN0ZDbEhUb3RUM1N3SldyUmJCZGd3d2N2SWlKbWZmSzZDSWZDemdYNHdJZTQ0ZDFlVFV2emkzc1Y4Z2FTTkstX2tENDVhQ2dZS0FXUVNBUmNTRlFIR1gyTWlHLXRJNXlmYzBFTTA5MnFTMnN6aFpnMDE3NSIsICJleHBpcmVzX2luIjogMzU5OSwgInJlZnJlc2hfdG9rZW4iOiAiMS8vMDVZWDNsZG04WXVJeUNnWUlBUkFBR0FVU053Ri1MOUlyYW1wNHlKR2Y5TnA0UW9aUlVGYkdQeVJXaTlWRHZUX0VLdVJ0cFJ3YnJUcHYxS1FVY1VtOFlBV1hQWURBNnhkckc0TSIsICJzY29wZSI6ICJodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL2RyaXZlLnJlYWRvbmx5IGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvdXNlcmluZm8ucHJvZmlsZSBodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL3VzZXJpbmZvLmVtYWlsIGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvZG9jdW1lbnRzLnJlYWRvbmx5IGh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvZ21haWwucmVhZG9ubHkgb3BlbmlkIiwgInRva2VuX3R5cGUiOiAiQmVhcmVyIiwgImlkX3Rva2VuIjogImV5SmhiR2NpT2lKU1V6STFOaUlzSW10cFpDSTZJalkyTUdWbU0ySTVOemcwWW1SbU5UWmxZbVU0TlRsbU5UYzNaamRtWWpKbE9HTXhZMlZtWm1JaUxDSjBlWEFpT2lKS1YxUWlmUS5leUpwYzNNaU9pSm9kSFJ3Y3pvdkwyRmpZMjkxYm5SekxtZHZiMmRzWlM1amIyMGlMQ0poZW5BaU9pSXhNRGs1TWpNM09EazBPVE0xTFhBemJqZG5hMncyY3prM2FHb3lNRGh1YjNGdE5ISm9PSEpyTTJkaVluWjBMbUZ3Y0hNdVoyOXZaMnhsZFhObGNtTnZiblJsYm5RdVkyOXRJaXdpWVhWa0lqb2lNVEE1T1RJek56ZzVORGt6TlMxd00yNDNaMnRzTm5NNU4yaHFNakE0Ym05eGJUUnlhRGh5YXpOblltSjJkQzVoY0hCekxtZHZiMmRzWlhWelpYSmpiMjUwWlc1MExtTnZiU0lzSW5OMVlpSTZJakV3TWpFMk5UUTNOakV4TkRnd05EQTVOakl6TUNJc0ltVnRZV2xzSWpvaVlXMWhjblJsZVVCbmJXRnBiQzVqYjIwaUxDSmxiV0ZwYkY5MlpYSnBabWxsWkNJNmRISjFaU3dpWVhSZmFHRnphQ0k2SW5OclYyWktjbTVsTlRaMmEyaFRMVnBKVEhOSlNXY2lMQ0p1YjI1alpTSTZJbkp2WlRNM1UzWkJjbmMyU0VwSVVsQTFTbTl0SWl3aWJtRnRaU0k2SWxOaGIybHljMlVnUVcxaGNuUmxhV1pwYnlJc0luQnBZM1IxY21VaU9pSm9kSFJ3Y3pvdkwyeG9NeTVuYjI5bmJHVjFjMlZ5WTI5dWRHVnVkQzVqYjIwdllTOUJRMmM0YjJOTWFWbFFNM0J0TFhSNmFITldURkp1T1ZoaVoxQlFWa2g0U0RCYWVUQmpSMmROZERKcVlVVkJZMnR3VDBsdlRGUkVaejF6T1RZdFl5SXNJbWRwZG1WdVgyNWhiV1VpT2lKVFlXOXBjbk5sSWl3aVptRnRhV3g1WDI1aGJXVWlPaUpCYldGeWRHVnBabWx2SWl3aWFXRjBJam94TnpRM05EQTJPVGszTENKbGVIQWlPakUzTkRjME1UQTFPVGQ5LmM5NWQ5WGtWREFQcjdjU3hBUWVtZzFYWXROSjREcHJhS2JIYlUwb0t1VmNlcDdybTNxQnRqOTZ4c0VnSWc5SXBWVlQ5Ym4zTDF2alU5OTYyVDdQeC1BWEdNYzRab25YX3FYTGc2M1pueGhBVHNIcXdoQ2VoS2N5NVZxYkxkbVVtYnlsZmFYR0pIbFp5ZDhRbkU1RVppY3B1d3ZhN1U5Y3F2Q184ZTVERkN6Ymk5d0V2bHNmc21Vb3U3U0dWdERkX2dqVUxfNTY4RldhSktrNmt3aUhBZXRUaEQ5WmZUaGgybE1vZHdrVHhuOXVzTWhNZ2oyeENvLXR4bjdqa3hRNnk1NGpINE1DRnhUZzk4V2lRdFJvWkxUbm9neXVYbGZzVkI3V3FQdllqTjlrR2tmMnU3SzJCOHFuMkJGT1NjTFJPaHRGSzJDcTIzVm1WZzhNMmVXQlB6dyIsICJyZWZyZXNoX3Rva2VuX2V4cGlyZXNfaW4iOiA2MDQ3OTksICJleHBpcmVzX2F0IjogMTc0NzQxMDU5NiwgInVzZXJpbmZvIjogeyJpc3MiOiAiaHR0cHM6Ly9hY2NvdW50cy5nb29nbGUuY29tIiwgImF6cCI6ICIxMDk5MjM3ODk0OTM1LXAzbjdna2w2czk3aGoyMDhub3FtNHJoOHJrM2diYnZ0LmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29tIiwgImF1ZCI6ICIxMDk5MjM3ODk0OTM1LXAzbjdna2w2czk3aGoyMDhub3FtNHJoOHJrM2diYnZ0LmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29tIiwgInN1YiI6ICIxMDIxNjU0NzYxMTQ4MDQwOTYyMzAiLCAiZW1haWwiOiAiYW1hcnRleUBnbWFpbC5jb20iLCAiZW1haWxfdmVyaWZpZWQiOiB0cnVlLCAiYXRfaGFzaCI6ICJza1dmSnJuZTU2dmtoUy1aSUxzSUlnIiwgIm5vbmNlIjogInJvZTM3U3ZBcnc2SEpIUlA1Sm9tIiwgIm5hbWUiOiAiU2FvaXJzZSBBbWFydGVpZmlvIiwgInBpY3R1cmUiOiAiaHR0cHM6Ly9saDMuZ29vZ2xldXNlcmNvbnRlbnQuY29tL2EvQUNnOG9jTGlZUDNwbS10emhzVkxSbjlYYmdQUFZIeEgwWnkwY0dnTXQyamFFQWNrcE9Jb0xURGc9czk2LWMiLCAiZ2l2ZW5fbmFtZSI6ICJTYW9pcnNlIiwgImZhbWlseV9uYW1lIjogIkFtYXJ0ZWlmaW8iLCAiaWF0IjogMTc0NzQwNjk5NywgImV4cCI6IDE3NDc0MTA1OTd9fSwgInNlc3Npb25faWQiOiAiYzU4ZmQ1MWYtNDAzZC00MjU3LTllMTgtMTc3MzdlNDRmZDNmIn0=.aCdQlQ.qHKMWsxfHuBLHnk3Ck3Ux_tiqp8')

base_url = 'http://localhost:5008'

def test_simple_request():
    """Test a simple request to see full error."""
    print("Testing simple GET request to /tus/user/uploads...")
    
    try:
        response = session.get(f'{base_url}/tus/user/uploads', params={'limit': 5})
        print(f"Status Code: {response.status_code}")
        print(f"Headers: {dict(response.headers)}")
        
        try:
            json_response = response.json()
            print(f"JSON Response: {json.dumps(json_response, indent=2)}")
        except:
            print(f"Text Response: {response.text}")
    except Exception as e:
        print(f"Exception: {type(e).__name__}: {e}")

def test_post_request():
    """Test POST request with minimal data."""
    print("\n\nTesting POST request to /tus/user/uploads/search...")
    
    try:
        # Minimal request
        request_data = {
            "limit": 5
        }
        
        response = session.post(f'{base_url}/tus/user/uploads/search', json=request_data)
        print(f"Status Code: {response.status_code}")
        
        try:
            json_response = response.json()
            print(f"JSON Response: {json.dumps(json_response, indent=2)}")
        except:
            print(f"Text Response: {response.text}")
    except Exception as e:
        print(f"Exception: {type(e).__name__}: {e}")

def test_old_endpoint():
    """Test the old semantic search endpoint to see if it works."""
    print("\n\nTesting old semantic search endpoint...")
    
    try:
        response = session.get(f'{base_url}/tus/search/semantic', params={'query': 'test', 'limit': 5})
        print(f"Status Code: {response.status_code}")
        
        try:
            json_response = response.json()
            print(f"JSON Response: {json.dumps(json_response, indent=2)}")
        except:
            print(f"Text Response: {response.text}")
    except Exception as e:
        print(f"Exception: {type(e).__name__}: {e}")

def test_list_uploads():
    """Test the existing list uploads endpoint."""
    print("\n\nTesting existing list uploads endpoint...")
    
    try:
        response = session.get(f'{base_url}/tus/', params={'limit': 5})
        print(f"Status Code: {response.status_code}")
        
        try:
            json_response = response.json()
            print(f"JSON Response: {json.dumps(json_response, indent=2)}")
        except:
            print(f"Text Response: {response.text}")
    except Exception as e:
        print(f"Exception: {type(e).__name__}: {e}")

if __name__ == "__main__":
    test_simple_request()
    test_post_request()
    test_old_endpoint()
    test_list_uploads()