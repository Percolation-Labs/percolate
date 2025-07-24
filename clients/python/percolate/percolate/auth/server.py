"""
OAuth 2.1 compliant authorization server
"""

from typing import Dict, Optional, Any
import os
from urllib.parse import urlencode, urlparse

from .providers import AuthProvider, BearerTokenProvider, GoogleOAuthProvider
from .models import (
    AuthRequest,
    AuthResponse,
    TokenRequest,
    TokenResponse,
    TokenInfo,
    OAuthMetadata,
    MCPAuthChallenge,
    AuthError
)


class OAuthServer:
    """
    OAuth 2.1 authorization server with support for multiple providers
    """
    
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip('/')
        self.providers: Dict[str, AuthProvider] = {}
        
        # Initialize default providers
        self._init_default_providers()
        
        # Server metadata
        self.metadata = OAuthMetadata(
            issuer=self.base_url,
            authorization_endpoint=f"{self.base_url}/auth/authorize",
            token_endpoint=f"{self.base_url}/auth/token",
            registration_endpoint=f"{self.base_url}/auth/register",
            revocation_endpoint=f"{self.base_url}/auth/revoke",
            introspection_endpoint=f"{self.base_url}/auth/introspect",
            scopes_supported=["read", "write", "admin"],
            code_challenge_methods_supported=["S256", "plain"]
        )
    
    def _init_default_providers(self):
        """Initialize default authentication providers"""
        # Always add bearer token provider
        self.providers["bearer"] = BearerTokenProvider()
        
        # Add Google OAuth if configured
        google_client_id = os.getenv("GOOGLE_OAUTH_CLIENT_ID")
        google_client_secret = os.getenv("GOOGLE_OAUTH_CLIENT_SECRET")
        google_redirect_uri = os.getenv("GOOGLE_OAUTH_REDIRECT_URI", f"{self.base_url}/auth/google/callback")
        
        if google_client_id and google_client_secret:
            self.providers["google"] = GoogleOAuthProvider(
                client_id=google_client_id,
                client_secret=google_client_secret,
                redirect_uri=google_redirect_uri
            )
    
    def register_provider(self, name: str, provider: AuthProvider):
        """Register a new authentication provider"""
        self.providers[name] = provider
    
    async def authorize(self, request: AuthRequest) -> AuthResponse:
        """
        Handle authorization request
        
        Routes to appropriate provider based on request parameters
        """
        # Determine provider
        provider_name = request.provider or self._detect_provider(request)
        
        if provider_name not in self.providers:
            raise AuthError("invalid_request", f"Unknown provider: {provider_name}")
        
        provider = self.providers[provider_name]
        return await provider.authorize(request)
    
    async def token(self, request: TokenRequest) -> TokenResponse:
        """
        Handle token request
        
        Routes to appropriate provider based on grant type and metadata
        """
        # For authorization_code grant, we need to determine which provider issued the code
        # This is a simplified implementation - in production, store provider with code
        
        # Try each provider until one succeeds
        last_error = None
        for provider in self.providers.values():
            try:
                return await provider.token(request)
            except AuthError as e:
                last_error = e
                continue
        
        if last_error:
            raise last_error
        else:
            raise AuthError("invalid_grant", "No provider could handle this request")
    
    async def validate_token(self, token: str, token_hint: Optional[str] = None) -> TokenInfo:
        """
        Validate a token across all providers
        """
        # Try each provider
        last_error = None
        for provider in self.providers.values():
            try:
                return await provider.validate(token)
            except (AuthError, Exception) as e:
                last_error = e
                continue
        
        if isinstance(last_error, AuthError):
            raise last_error
        else:
            raise AuthError("invalid_token", "Token validation failed")
    
    async def refresh_token(self, refresh_token: str) -> TokenResponse:
        """
        Refresh a token
        """
        # Try each provider
        last_error = None
        for provider in self.providers.values():
            try:
                return await provider.refresh(refresh_token)
            except AuthError as e:
                last_error = e
                continue
        
        if last_error:
            raise last_error
        else:
            raise AuthError("invalid_grant", "Refresh token not valid")
    
    async def revoke_token(self, token: str, token_hint: Optional[str] = None) -> bool:
        """
        Revoke a token
        """
        # Try to revoke with each provider
        revoked = False
        for provider in self.providers.values():
            try:
                if await provider.revoke(token):
                    revoked = True
            except Exception:
                continue
        
        return revoked
    
    def _detect_provider(self, request: AuthRequest) -> str:
        """
        Detect provider from request
        """
        # If bearer token and email provided, use bearer provider
        if request.bearer_token and request.user_email:
            return "bearer"
        
        # Default to Google for OAuth flows
        return "google"
    
    def get_mcp_challenge(self) -> MCPAuthChallenge:
        """
        Get MCP authentication challenge
        """
        return MCPAuthChallenge(
            url=f"{self.base_url}/auth/authorize",
            token_url=f"{self.base_url}/auth/token"
        )
    
    def get_oauth_metadata(self) -> Dict[str, Any]:
        """
        Get OAuth 2.1 server metadata
        """
        return self.metadata.model_dump(exclude_none=True)
    
    def build_auth_url(
        self, 
        client_id: str,
        redirect_uri: str,
        state: Optional[str] = None,
        scope: Optional[str] = None,
        code_challenge: Optional[str] = None,
        code_challenge_method: Optional[str] = None,
        provider: Optional[str] = None
    ) -> str:
        """
        Build authorization URL
        """
        params = {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri
        }
        
        if state:
            params["state"] = state
        if scope:
            params["scope"] = scope
        if code_challenge:
            params["code_challenge"] = code_challenge
            params["code_challenge_method"] = code_challenge_method or "S256"
        if provider:
            params["provider"] = provider
        
        return f"{self.base_url}/auth/authorize?{urlencode(params)}"