"""
Example OAuth client for Percolate

Demonstrates how to authenticate with Percolate using:
1. Bearer token authentication
2. Google OAuth flow
"""

import asyncio
import httpx
import os
import secrets
import hashlib
import base64
from urllib.parse import urlencode, parse_qs, urlparse
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading
import json


class PercolateOAuthClient:
    """OAuth client for Percolate API"""
    
    def __init__(self, base_url="http://localhost:8000", client_id="percolate-client"):
        self.base_url = base_url.rstrip('/')
        self.client_id = client_id
        self.session = httpx.AsyncClient()
        self.access_token = None
        self.refresh_token = None
    
    async def discover_oauth_config(self):
        """Discover OAuth configuration"""
        # Get protected resource info
        resp = await self.session.get(f"{self.base_url}/.well-known/oauth-protected-resource")
        resp.raise_for_status()
        protected_resource = resp.json()
        
        # Get authorization server metadata
        auth_server_url = protected_resource["authorization_server"]
        resp = await self.session.get(auth_server_url)
        resp.raise_for_status()
        
        return resp.json()
    
    async def authenticate_with_bearer(self, api_key: str, user_email: str):
        """Authenticate using bearer token"""
        # Test the authentication
        resp = await self.session.get(
            f"{self.base_url}/api/test",
            headers={
                "Authorization": f"Bearer {api_key}",
                "X-User-Email": user_email
            }
        )
        
        if resp.status_code == 200:
            self.access_token = api_key
            print(f"✅ Authenticated with bearer token for {user_email}")
            return True
        else:
            print(f"❌ Authentication failed: {resp.status_code}")
            return False
    
    async def authenticate_with_google(self, redirect_port=8080):
        """Authenticate using Google OAuth"""
        # Discover OAuth config
        config = await self.discover_oauth_config()
        
        # Generate PKCE parameters
        code_verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode('utf-8').rstrip('=')
        code_challenge = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode()).digest()
        ).decode('utf-8').rstrip('=')
        
        # State for CSRF protection
        state = secrets.token_urlsafe(32)
        
        # Build authorization URL
        auth_params = {
            "response_type": "code",
            "client_id": self.client_id,
            "redirect_uri": f"http://localhost:{redirect_port}/callback",
            "scope": "read write",
            "state": state,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
            "provider": "google"
        }
        
        auth_url = f"{config['authorization_endpoint']}?{urlencode(auth_params)}"
        
        # Set up local server to receive callback
        auth_code = None
        
        class CallbackHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                nonlocal auth_code
                
                # Parse query parameters
                query = urlparse(self.path).query
                params = parse_qs(query)
                
                if 'code' in params:
                    auth_code = params['code'][0]
                    self.send_response(200)
                    self.send_header('Content-type', 'text/html')
                    self.end_headers()
                    self.wfile.write(b"""
                        <html>
                        <body>
                        <h1>Authentication Successful!</h1>
                        <p>You can close this window.</p>
                        </body>
                        </html>
                    """)
                else:
                    self.send_response(400)
                    self.end_headers()
            
            def log_message(self, format, *args):
                pass  # Suppress log messages
        
        # Start local server
        server = HTTPServer(('localhost', redirect_port), CallbackHandler)
        server_thread = threading.Thread(target=server.serve_forever)
        server_thread.daemon = True
        server_thread.start()
        
        # Open browser
        print(f"Opening browser for authentication...")
        webbrowser.open(auth_url)
        
        # Wait for callback
        print("Waiting for authentication callback...")
        while auth_code is None:
            await asyncio.sleep(0.1)
        
        server.shutdown()
        
        # Exchange code for tokens
        token_data = {
            "grant_type": "authorization_code",
            "code": auth_code,
            "redirect_uri": f"http://localhost:{redirect_port}/callback",
            "client_id": self.client_id,
            "code_verifier": code_verifier
        }
        
        resp = await self.session.post(
            config['token_endpoint'],
            data=token_data
        )
        
        if resp.status_code == 200:
            tokens = resp.json()
            self.access_token = tokens['access_token']
            self.refresh_token = tokens.get('refresh_token')
            print("✅ Authenticated with Google OAuth")
            return True
        else:
            print(f"❌ Token exchange failed: {resp.status_code} {resp.text}")
            return False
    
    async def make_authenticated_request(self, path: str, method="GET", **kwargs):
        """Make authenticated API request"""
        if not self.access_token:
            raise Exception("Not authenticated")
        
        headers = kwargs.pop('headers', {})
        headers['Authorization'] = f"Bearer {self.access_token}"
        
        # Add X-User-Email for bearer token auth
        if '@' in self.access_token:  # Simple check if it's not an OAuth token
            headers['X-User-Email'] = kwargs.pop('user_email', None)
        
        resp = await self.session.request(
            method,
            f"{self.base_url}{path}",
            headers=headers,
            **kwargs
        )
        
        return resp
    
    async def close(self):
        """Close the client session"""
        await self.session.aclose()


async def main():
    """Example usage of PercolateOAuthClient"""
    
    client = PercolateOAuthClient()
    
    # Example 1: Bearer token authentication
    print("\n=== Bearer Token Authentication ===")
    api_key = os.getenv("PERCOLATE_API_KEY", "sk-test-key")
    user_email = os.getenv("PERCOLATE_USER_EMAIL", "test@example.com")
    
    if api_key and user_email:
        success = await client.authenticate_with_bearer(api_key, user_email)
        
        if success:
            # Make authenticated request
            resp = await client.make_authenticated_request(
                "/api/test",
                user_email=user_email
            )
            print(f"API Response: {resp.status_code}")
    
    # Example 2: Google OAuth authentication
    print("\n=== Google OAuth Authentication ===")
    print("Starting OAuth flow...")
    
    # Create new client for OAuth
    oauth_client = PercolateOAuthClient()
    success = await oauth_client.authenticate_with_google()
    
    if success:
        # Make authenticated request
        resp = await oauth_client.make_authenticated_request("/api/test")
        print(f"API Response: {resp.status_code}")
    
    # Clean up
    await client.close()
    await oauth_client.close()


if __name__ == "__main__":
    asyncio.run(main())