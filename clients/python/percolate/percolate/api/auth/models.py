"""
Authentication models and data structures
"""

from typing import Optional, List, Dict, Any, Union
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from pydantic import BaseModel, Field, ConfigDict


class GrantType(str, Enum):
    """OAuth 2.1 grant types"""
    AUTHORIZATION_CODE = "authorization_code"
    REFRESH_TOKEN = "refresh_token"
    CLIENT_CREDENTIALS = "client_credentials"


class TokenType(str, Enum):
    """Token types"""
    BEARER = "Bearer"


class AuthProvider(str, Enum):
    """Authentication providers"""
    BEARER = "bearer"
    GOOGLE = "google"
    PERCOLATE = "percolate"


class AuthRequest(BaseModel):
    """Authorization request"""
    model_config = ConfigDict(extra="allow")
    
    response_type: str = Field("code", description="OAuth response type")
    client_id: str = Field(..., description="Client identifier")
    redirect_uri: Optional[str] = Field(None, description="Redirect URI")
    scope: Optional[str] = Field(None, description="Requested scopes")
    state: Optional[str] = Field(None, description="Client state")
    code_challenge: Optional[str] = Field(None, description="PKCE challenge")
    code_challenge_method: Optional[str] = Field("S256", description="PKCE method")
    
    # Provider-specific
    provider: Optional[AuthProvider] = Field(None, description="Auth provider")
    
    # Bearer token specific
    bearer_token: Optional[str] = Field(None, description="Bearer token")
    user_email: Optional[str] = Field(None, description="User email")


class AuthResponse(BaseModel):
    """Authorization response"""
    code: Optional[str] = Field(None, description="Authorization code")
    state: Optional[str] = Field(None, description="Client state")
    redirect_uri: Optional[str] = Field(None, description="Redirect URI")
    error: Optional[str] = Field(None, description="Error code")
    error_description: Optional[str] = Field(None, description="Error description")


class TokenRequest(BaseModel):
    """Token request"""
    model_config = ConfigDict(extra="allow")
    
    grant_type: GrantType = Field(..., description="Grant type")
    code: Optional[str] = Field(None, description="Authorization code")
    redirect_uri: Optional[str] = Field(None, description="Redirect URI")
    client_id: Optional[str] = Field(None, description="Client ID")
    client_secret: Optional[str] = Field(None, description="Client secret")
    code_verifier: Optional[str] = Field(None, description="PKCE verifier")
    refresh_token: Optional[str] = Field(None, description="Refresh token")
    scope: Optional[str] = Field(None, description="Requested scopes")


class TokenResponse(BaseModel):
    """Token response"""
    access_token: str = Field(..., description="Access token")
    token_type: TokenType = Field(TokenType.BEARER, description="Token type")
    expires_in: Optional[int] = Field(3600, description="Expiration in seconds")
    refresh_token: Optional[str] = Field(None, description="Refresh token")
    scope: Optional[str] = Field(None, description="Granted scopes")
    id_token: Optional[str] = Field(None, description="OpenID Connect ID token")


class TokenInfo(BaseModel):
    """Token information from validation"""
    active: bool = Field(..., description="Is token active")
    scope: Optional[str] = Field(None, description="Token scopes")
    client_id: Optional[str] = Field(None, description="Client ID")
    username: Optional[str] = Field(None, description="Username")
    email: Optional[str] = Field(None, description="User email")
    exp: Optional[int] = Field(None, description="Expiration timestamp")
    iat: Optional[int] = Field(None, description="Issued at timestamp")
    sub: Optional[str] = Field(None, description="Subject (user ID)")
    aud: Optional[Union[str, List[str]]] = Field(None, description="Audience")
    iss: Optional[str] = Field(None, description="Issuer")
    provider: Optional[str] = Field(None, description="Auth provider")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Additional metadata")


@dataclass
class AuthContext:
    """Authentication context for requests"""
    user_id: str
    email: str
    provider: str
    scopes: List[str]
    token: str
    metadata: Dict[str, Any] = None
    
    def __post_init__(self):
        if self.metadata is None:
            self.metadata = {}
    
    def has_scope(self, scope: str) -> bool:
        """Check if context has a specific scope"""
        return scope in self.scopes
    
    def has_any_scope(self, scopes: List[str]) -> bool:
        """Check if context has any of the scopes"""
        return any(scope in self.scopes for scope in scopes)
    
    def has_all_scopes(self, scopes: List[str]) -> bool:
        """Check if context has all scopes"""
        return all(scope in self.scopes for scope in scopes)


class AuthError(Exception):
    """Authentication error"""
    def __init__(
        self, 
        error: str, 
        error_description: Optional[str] = None,
        status_code: int = 401
    ):
        self.error = error
        self.error_description = error_description
        self.status_code = status_code
        super().__init__(error_description or error)


class TokenExpiredError(AuthError):
    """Token has expired"""
    def __init__(self, message: str = "Token has expired"):
        super().__init__("token_expired", message, 401)


class InvalidTokenError(AuthError):
    """Invalid token"""
    def __init__(self, message: str = "Invalid token"):
        super().__init__("invalid_token", message, 401)


class InsufficientScopeError(AuthError):
    """Insufficient scope for request"""
    def __init__(self, required_scope: str):
        super().__init__(
            "insufficient_scope",
            f"Required scope: {required_scope}",
            403
        )


class OAuthMetadata(BaseModel):
    """OAuth 2.1 server metadata"""
    issuer: str = Field(..., description="Issuer identifier")
    authorization_endpoint: str = Field(..., description="Authorization endpoint")
    token_endpoint: str = Field(..., description="Token endpoint")
    token_endpoint_auth_methods_supported: List[str] = Field(
        default_factory=lambda: ["client_secret_post", "client_secret_basic"]
    )
    jwks_uri: Optional[str] = Field(None, description="JWKS endpoint")
    registration_endpoint: Optional[str] = Field(None, description="Registration endpoint")
    scopes_supported: Optional[List[str]] = Field(None, description="Supported scopes")
    response_types_supported: List[str] = Field(
        default_factory=lambda: ["code", "token"]
    )
    grant_types_supported: List[str] = Field(
        default_factory=lambda: ["authorization_code", "refresh_token"]
    )
    revocation_endpoint: Optional[str] = Field(None, description="Revocation endpoint")
    introspection_endpoint: Optional[str] = Field(None, description="Introspection endpoint")
    code_challenge_methods_supported: List[str] = Field(
        default_factory=lambda: ["S256", "plain"]
    )


class MCPAuthChallenge(BaseModel):
    """MCP authentication challenge"""
    url: str = Field(..., description="Authorization URL")
    token_url: str = Field(..., description="Token exchange URL")