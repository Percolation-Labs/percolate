"""
Percolate Authentication System

OAuth 2.1 compliant authentication with support for multiple providers.
"""

from .server import OAuthServer
from .providers import AuthProvider, BearerTokenProvider, GoogleOAuthProvider
from .models import (
    AuthRequest,
    AuthResponse,
    TokenRequest,
    TokenResponse,
    TokenInfo,
    AuthContext,
    AuthError,
    TokenExpiredError,
    InvalidTokenError,
    InsufficientScopeError,
    GrantType,
    OAuthMetadata,
    MCPAuthChallenge
)
from .middleware import AuthMiddleware, require_auth, get_auth

__all__ = [
    # Server
    "OAuthServer",
    
    # Providers
    "AuthProvider",
    "BearerTokenProvider", 
    "GoogleOAuthProvider",
    
    # Models
    "AuthRequest",
    "AuthResponse",
    "TokenRequest",
    "TokenResponse",
    "TokenInfo",
    "AuthContext",
    "AuthError",
    "TokenExpiredError",
    "InvalidTokenError",
    "InsufficientScopeError",
    "GrantType",
    "OAuthMetadata",
    "MCPAuthChallenge",
    
    # Middleware
    "AuthMiddleware",
    "require_auth",
    "get_auth",
]