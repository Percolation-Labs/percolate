"""
OAuth controller for handling authentication logic
"""

from typing import Optional, Dict, Any
import os
import secrets
from urllib.parse import urlencode

from ..auth.server import OAuthServer
from ..auth.models import (
    AuthRequest,
    AuthResponse,
    TokenRequest,
    TokenResponse,
    AuthError,
    GrantType
)
from ...utils import logger


class OAuthController:
    """Controller for OAuth operations"""
    
    def __init__(self, oauth_server: OAuthServer):
        self.oauth_server = oauth_server
    
    async def process_authorization(
        self,
        auth_request: AuthRequest,
        authorization_header: Optional[str] = None,
        user_email_header: Optional[str] = None
    ) -> AuthResponse:
        """
        Process authorization request
        
        Handles different authentication flows:
        - Bearer token with email header
        - Environment credentials
        - OAuth provider flows
        """
        # Check for bearer token auth
        if authorization_header and authorization_header.startswith("Bearer "):
            auth_request.bearer_token = authorization_header[7:]
            auth_request.user_email = user_email_header
        
        # Check for credentials in environment (for automated flows)
        oauth_username = os.getenv("OAUTH_USERNAME")
        oauth_password = os.getenv("OAUTH_PASSWORD")
        
        if oauth_username and oauth_password:
            # Automated flow - directly get auth code
            # This would validate credentials with provider
            auth_request.bearer_token = f"env-{oauth_username}"
            auth_request.user_email = oauth_username
        
        # Process authorization
        return await self.oauth_server.authorize(auth_request)
    
    async def exchange_token(self, token_request: TokenRequest) -> TokenResponse:
        """
        Exchange authorization code or refresh token for access token
        """
        if token_request.grant_type == GrantType.AUTHORIZATION_CODE:
            return await self.oauth_server.token(token_request)
        elif token_request.grant_type == GrantType.REFRESH_TOKEN:
            return await self.oauth_server.refresh_token(token_request.refresh_token)
        else:
            raise AuthError(
                "unsupported_grant_type",
                f"Grant type {token_request.grant_type} not supported"
            )
    
    async def revoke_token(
        self,
        token: str,
        token_type_hint: Optional[str] = None
    ) -> bool:
        """Revoke a token"""
        return await self.oauth_server.revoke_token(token, token_type_hint)
    
    async def introspect_token(
        self,
        token: str,
        token_type_hint: Optional[str] = None
    ) -> Dict[str, Any]:
        """Introspect a token"""
        try:
            token_info = await self.oauth_server.validate_token(token, token_type_hint)
            return token_info.model_dump(exclude_none=True)
        except AuthError:
            # Return inactive token per spec
            return {"active": False}
        except Exception as e:
            logger.error(f"Introspection error: {e}")
            return {"active": False}
    
    def build_redirect_url(
        self,
        base_uri: str,
        code: Optional[str] = None,
        state: Optional[str] = None,
        error: Optional[str] = None,
        error_description: Optional[str] = None
    ) -> str:
        """Build redirect URL with parameters"""
        params = {}
        
        if code:
            params["code"] = code
        if state:
            params["state"] = state
        if error:
            params["error"] = error
            if error_description:
                params["error_description"] = error_description
        
        return f"{base_uri}?{urlencode(params)}"
    
    def generate_login_html(
        self,
        auth_request: AuthRequest,
        error: Optional[str] = None
    ) -> str:
        """Generate login form HTML"""
        # Serialize request params for hidden fields
        hidden_fields = []
        for field, value in auth_request.model_dump(exclude_none=True).items():
            if field not in ["bearer_token", "user_email"]:
                hidden_fields.append(f'<input type="hidden" name="{field}" value="{value}">')
        
        hidden_html = "\n".join(hidden_fields)
        
        error_html = ""
        if error:
            error_html = f'<div style="color: red; margin-bottom: 10px;">{error}</div>'
        
        return f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>Percolate Login</title>
            <style>
                body {{
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    margin: 0;
                    background-color: #f5f5f5;
                }}
                .login-form {{
                    background: white;
                    padding: 2rem;
                    border-radius: 8px;
                    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                    width: 100%;
                    max-width: 400px;
                }}
                h2 {{
                    margin-top: 0;
                    color: #333;
                }}
                .form-group {{
                    margin-bottom: 1rem;
                }}
                label {{
                    display: block;
                    margin-bottom: 0.5rem;
                    color: #666;
                }}
                input[type="email"],
                input[type="password"] {{
                    width: 100%;
                    padding: 0.5rem;
                    border: 1px solid #ddd;
                    border-radius: 4px;
                    font-size: 1rem;
                }}
                button {{
                    width: 100%;
                    padding: 0.75rem;
                    background-color: #007bff;
                    color: white;
                    border: none;
                    border-radius: 4px;
                    font-size: 1rem;
                    cursor: pointer;
                }}
                button:hover {{
                    background-color: #0056b3;
                }}
                .divider {{
                    text-align: center;
                    margin: 1.5rem 0;
                    color: #666;
                    position: relative;
                }}
                .divider:before {{
                    content: "";
                    position: absolute;
                    top: 50%;
                    left: 0;
                    right: 0;
                    height: 1px;
                    background: #ddd;
                }}
                .divider span {{
                    background: white;
                    padding: 0 1rem;
                    position: relative;
                }}
                .google-login {{
                    width: 100%;
                    padding: 0.75rem;
                    background-color: #4285f4;
                    color: white;
                    border: none;
                    border-radius: 4px;
                    font-size: 1rem;
                    cursor: pointer;
                    text-decoration: none;
                    display: block;
                    text-align: center;
                }}
                .google-login:hover {{
                    background-color: #357ae8;
                }}
            </style>
        </head>
        <body>
            <div class="login-form">
                <h2>Percolate Login</h2>
                {error_html}
                <form method="post">
                    <div class="form-group">
                        <label for="email">Email</label>
                        <input type="email" id="email" name="email" required>
                    </div>
                    <div class="form-group">
                        <label for="token">API Token</label>
                        <input type="password" id="token" name="token" required>
                    </div>
                    {hidden_html}
                    <button type="submit">Login with API Token</button>
                </form>
                <div class="divider">
                    <span>OR</span>
                </div>
                <a href="/auth/authorize?provider=google&{urlencode(auth_request.model_dump(exclude_none=True, exclude={{'bearer_token', 'user_email', 'provider'}}))}" class="google-login">
                    Login with Google
                </a>
            </div>
        </body>
        </html>
        """