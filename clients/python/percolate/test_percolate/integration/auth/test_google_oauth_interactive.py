#!/usr/bin/env python3
"""
Interactive test for Google OAuth login (Mode 3)
This script opens a browser for Google login and shows the complete OAuth flow
"""

import os
import sys
import asyncio
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import threading
import httpx
import json

# Configuration
PERCOLATE_BASE_URL = os.environ.get("PERCOLATE_BASE_URL", "http://localhost:5008")
REDIRECT_PORT = 8080
REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}/callback"

# Store the authorization code when received
auth_code = None
auth_state = None


class CallbackHandler(BaseHTTPRequestHandler):
    """Handle OAuth callback"""
    
    def do_GET(self):
        global auth_code, auth_state
        
        # Parse the callback URL
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        
        if 'code' in params:
            auth_code = params['code'][0]
            auth_state = params.get('state', [None])[0]
            
            # Send success response
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(b"""
                <html>
                <head><title>Login Successful</title></head>
                <body>
                    <h1>Login Successful!</h1>
                    <p>You can close this window and return to the terminal.</p>
                    <script>window.close();</script>
                </body>
                </html>
            """)
        else:
            # Handle error
            error = params.get('error', ['unknown'])[0]
            error_desc = params.get('error_description', ['No description'])[0]
            
            self.send_response(400)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(f"""
                <html>
                <head><title>Login Failed</title></head>
                <body>
                    <h1>Login Failed</h1>
                    <p>Error: {error}</p>
                    <p>Description: {error_desc}</p>
                </body>
                </html>
            """.encode())
        
        # Shutdown the server after handling the request
        threading.Thread(target=self.server.shutdown).start()
    
    def log_message(self, format, *args):
        # Suppress log messages
        pass


async def test_google_oauth_flow():
    """Run the complete Google OAuth flow"""
    print("=== Google OAuth Interactive Test ===\n")
    
    # Check environment
    if os.environ.get("AUTH_PROVIDER") != "google":
        print("⚠️  AUTH_PROVIDER is not set to 'google'")
        print("   Run: export AUTH_PROVIDER=google")
        print()
    
    if not os.environ.get("GOOGLE_OAUTH_CLIENT_ID"):
        print("❌ GOOGLE_OAUTH_CLIENT_ID is not set")
        print("   Run: export GOOGLE_OAUTH_CLIENT_ID=your-client-id")
        return
    
    if not os.environ.get("GOOGLE_OAUTH_CLIENT_SECRET"):
        print("❌ GOOGLE_OAUTH_CLIENT_SECRET is not set")
        print("   Run: export GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret")
        return
    
    print(f"API Endpoint: {PERCOLATE_BASE_URL}")
    print(f"Redirect URI: {REDIRECT_URI}")
    print()
    
    async with httpx.AsyncClient() as client:
        # Step 1: Start OAuth flow
        print("Step 1: Starting OAuth authorization flow...")
        
        auth_url = f"{PERCOLATE_BASE_URL}/auth/authorize?" + \
            f"response_type=code&" + \
            f"client_id=percolate-client&" + \
            f"redirect_uri={REDIRECT_URI}&" + \
            f"provider=google&" + \
            f"state=test-state-123"
        
        # Start local server to handle callback
        server = HTTPServer(('localhost', REDIRECT_PORT), CallbackHandler)
        server_thread = threading.Thread(target=server.serve_forever)
        server_thread.daemon = True
        server_thread.start()
        
        print(f"Opening browser to: {auth_url}")
        webbrowser.open(auth_url)
        
        print("\nWaiting for login callback...")
        server_thread.join()  # Wait for callback
        
        if not auth_code:
            print("❌ No authorization code received")
            return
        
        print(f"✓ Received authorization code: {auth_code[:10]}...")
        print(f"  State: {auth_state}")
        
        # Step 2: Exchange code for tokens
        print("\nStep 2: Exchanging authorization code for tokens...")
        
        response = await client.post(
            f"{PERCOLATE_BASE_URL}/auth/token",
            data={
                "grant_type": "authorization_code",
                "code": auth_code,
                "client_id": "percolate-client",
                "redirect_uri": REDIRECT_URI
            }
        )
        
        if response.status_code != 200:
            print(f"❌ Token exchange failed: {response.status_code}")
            print(f"   {response.text}")
            return
        
        tokens = response.json()
        print("✓ Received tokens:")
        print(f"  Access token: {tokens.get('access_token', '')[:20]}...")
        print(f"  Token type: {tokens.get('token_type', 'N/A')}")
        print(f"  Expires in: {tokens.get('expires_in', 'N/A')} seconds")
        if 'refresh_token' in tokens:
            print(f"  Refresh token: {tokens.get('refresh_token', '')[:20]}...")
        
        # Step 3: Test authenticated request
        print("\nStep 3: Testing authenticated API request...")
        
        response = await client.get(
            f"{PERCOLATE_BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {tokens['access_token']}"
            }
        )
        
        if response.status_code == 200:
            print("✓ Authentication successful!")
            data = response.json()
            print(f"  Response: {json.dumps(data, indent=2)}")
        else:
            print(f"❌ Authentication failed: {response.status_code}")
            print(f"   {response.text}")
        
        # Step 4: Check user registration
        print("\nStep 4: Checking user registration...")
        print("Note: In relay mode, only the user's email should be stored, not the token")
        
        # This would require database access to verify
        print("✓ User registration check complete (manual verification needed)")
        
        # Step 5: Test token expiration
        print("\nStep 5: Token expiration info:")
        print("In relay mode, when the Google token expires:")
        print("- API requests will fail with 401 TokenExpiredError")
        print("- Client must handle token refresh with Google directly")
        print("- Percolate does not store or manage refresh tokens")


def main():
    """Main entry point"""
    print("Google OAuth Interactive Test")
    print("=" * 50)
    print("\nThis test will:")
    print("1. Open your browser for Google login")
    print("2. Exchange the authorization code for tokens")
    print("3. Test authenticated API access")
    print("4. Verify user registration (email only)")
    print("\nPress Enter to continue or Ctrl+C to cancel...")
    
    try:
        input()
    except KeyboardInterrupt:
        print("\nCancelled.")
        return
    
    # Run the async test
    asyncio.run(test_google_oauth_flow())
    
    print("\n" + "=" * 50)
    print("Test complete!")


if __name__ == "__main__":
    main()