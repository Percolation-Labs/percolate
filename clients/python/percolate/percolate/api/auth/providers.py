"""
Authentication providers for OAuth 2.1 server
"""

from abc import ABC, abstractmethod
from typing import Optional, Dict, Any, List
import secrets
import hashlib
import base64
import httpx
import jwt
from datetime import datetime, timedelta

from percolate.models.p8.types import User
from percolate.utils import make_uuid
from .utils import (
    decode_jwt_token,
    extract_token_expiry,
    extract_user_info_from_token,
    store_user_with_token,
    is_valid_token_for_user,
    get_user_from_email
)
from .models import (
    AuthRequest,
    AuthResponse,
    TokenRequest,
    TokenResponse,
    TokenInfo,
    AuthError,
    InvalidTokenError,
    TokenExpiredError
)
import percolate as p8


class AuthProvider(ABC):
    """Base authentication provider interface"""
    
    @abstractmethod
    async def authorize(self, request: AuthRequest) -> AuthResponse:
        """Handle authorization request"""
        pass
    
    @abstractmethod
    async def token(self, request: TokenRequest) -> TokenResponse:
        """Exchange authorization code for tokens"""
        pass
    
    @abstractmethod
    async def validate(self, token: str) -> TokenInfo:
        """Validate an access token"""
        pass
    
    @abstractmethod
    async def refresh(self, refresh_token: str) -> TokenResponse:
        """Refresh an access token"""
        pass
    
    @abstractmethod
    async def revoke(self, token: str) -> bool:
        """Revoke a token"""
        pass


class BearerTokenProvider(AuthProvider):
    """
    Bearer token authentication provider.
    Requires both Authorization header and X-User-Email header.
    """
    
    def __init__(self):
        self.auth_codes: Dict[str, Dict[str, Any]] = {}  # Temporary storage for auth codes
    
    async def authorize(self, request: AuthRequest) -> AuthResponse:
        """
        Validate bearer token and email, return authorization code
        """
        if not request.bearer_token:
            raise AuthError("invalid_request", "Bearer token required")
        
        if not request.user_email:
            raise AuthError("invalid_request", "X-User-Email header required")
        
        # Validate token exists and belongs to user
        if not await is_valid_token_for_user(request.bearer_token, request.user_email):
            raise InvalidTokenError("Invalid bearer token for user")
        
        # Generate authorization code
        code = secrets.token_urlsafe(32)
        
        # Store code with metadata for exchange
        self.auth_codes[code] = {
            "client_id": request.client_id,
            "user_email": request.user_email,
            "bearer_token": request.bearer_token,
            "redirect_uri": request.redirect_uri,
            "code_challenge": request.code_challenge,
            "expires_at": datetime.utcnow() + timedelta(minutes=10)
        }
        
        return AuthResponse(
            code=code,
            state=request.state,
            redirect_uri=request.redirect_uri
        )
    
    async def token(self, request: TokenRequest) -> TokenResponse:
        """
        Exchange authorization code for tokens
        """
        if request.grant_type == "authorization_code":
            # Validate code exists
            if request.code not in self.auth_codes:
                raise AuthError("invalid_grant", "Invalid authorization code")
            
            code_data = self.auth_codes[request.code]
            
            # Check expiration
            if datetime.utcnow() > code_data["expires_at"]:
                del self.auth_codes[request.code]
                raise AuthError("invalid_grant", "Authorization code expired")
            
            # Validate PKCE if present
            if code_data.get("code_challenge"):
                if not request.code_verifier:
                    raise AuthError("invalid_request", "Code verifier required")
                
                # Verify challenge
                verifier_hash = base64.urlsafe_b64encode(
                    hashlib.sha256(request.code_verifier.encode()).digest()
                ).decode().rstrip("=")
                
                if verifier_hash != code_data["code_challenge"]:
                    raise AuthError("invalid_grant", "Invalid code verifier")
            
            # Get user
            user = await get_user_from_email(code_data["user_email"])
            if not user:
                raise AuthError("invalid_grant", "User not found")
            
            # Clean up code
            del self.auth_codes[request.code]
            
            # Return the stored bearer token as access token
            return TokenResponse(
                access_token=code_data["bearer_token"],
                token_type="Bearer",
                expires_in=None,  # Bearer tokens don't expire in this implementation
                scope="read write"
            )
        
        else:
            raise AuthError("unsupported_grant_type", f"Grant type {request.grant_type} not supported")
    
    async def validate(self, token: str) -> TokenInfo:
        """
        Validate bearer token
        """
        # Get all users with this token
        user_repo = p8.repository(User)
        users = user_repo.select(token=token)
        
        if not users:
            raise InvalidTokenError("Token not found")
        
        user = User(**users[0])
        
        # Check expiry if set
        if user.token_expiry and datetime.utcnow() > user.token_expiry:
            raise TokenExpiredError()
        
        return TokenInfo(
            active=True,
            username=user.name,
            email=user.email,
            sub=str(user.id),
            client_id="bearer-client",
            scope="read write",
            provider="bearer",
            metadata={
                "user_id": str(user.id),
                "role_level": user.role_level,
                "groups": user.groups or []
            }
        )
    
    async def refresh(self, refresh_token: str) -> TokenResponse:
        """
        Bearer tokens don't support refresh in this implementation
        """
        raise AuthError("unsupported_grant_type", "Bearer tokens cannot be refreshed")
    
    async def revoke(self, token: str) -> bool:
        """
        Revoke a bearer token by removing it from the user
        """
        user_repo = p8.repository(User)
        users = user_repo.select(token=token)
        
        if users:
            user = User(**users[0])
            user.token = None
            user.token_expiry = None
            user_repo.update_records(user)
            return True
        
        return False


class GoogleOAuthProvider(AuthProvider):
    """
    Google OAuth 2.0 authentication provider
    """
    
    def __init__(self, client_id: str, client_secret: str, redirect_uri: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.auth_codes: Dict[str, Dict[str, Any]] = {}
        
        # Google OAuth endpoints (from https://accounts.google.com/.well-known/openid-configuration)
        self.auth_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"
        self.token_endpoint = "https://oauth2.googleapis.com/token"
        self.userinfo_endpoint = "https://openidconnect.googleapis.com/v1/userinfo"
        self.jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
    
    async def authorize(self, request: AuthRequest) -> AuthResponse:
        """
        Generate Google OAuth authorization URL
        """
        # For Google OAuth, we need to redirect to Google's auth endpoint
        # Store request data for later validation
        state = request.state or secrets.token_urlsafe(32)
        
        self.auth_codes[state] = {
            "client_id": request.client_id,
            "redirect_uri": request.redirect_uri or self.redirect_uri,
            "code_challenge": request.code_challenge,
            "expires_at": datetime.utcnow() + timedelta(minutes=10)
        }
        
        # Build Google OAuth URL
        params = {
            "client_id": self.client_id,
            "redirect_uri": request.redirect_uri or self.redirect_uri,
            "response_type": "code",
            "scope": request.scope or "openid email profile",
            "state": state,
            "access_type": "offline",
            "prompt": "consent"
        }
        
        # Add PKCE if provided
        if request.code_challenge:
            params["code_challenge"] = request.code_challenge
            params["code_challenge_method"] = request.code_challenge_method
        
        auth_url = f"{self.auth_endpoint}?" + "&".join(f"{k}={v}" for k, v in params.items())
        
        # Return a response indicating redirect needed
        return AuthResponse(
            redirect_uri=auth_url,
            state=state
        )
    
    async def token(self, request: TokenRequest) -> TokenResponse:
        """
        Exchange Google authorization code for tokens
        """
        if request.grant_type == "authorization_code":
            # Exchange code with Google
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    self.token_endpoint,
                    data={
                        "code": request.code,
                        "client_id": self.client_id,
                        "client_secret": self.client_secret,
                        "redirect_uri": request.redirect_uri or self.redirect_uri,
                        "grant_type": "authorization_code",
                        "code_verifier": request.code_verifier
                    }
                )
                
                if response.status_code != 200:
                    error_data = response.json()
                    raise AuthError(
                        error_data.get("error", "invalid_grant"),
                        error_data.get("error_description", "Failed to exchange code")
                    )
                
                token_data = response.json()
                
                # Get user info
                userinfo_response = await client.get(
                    self.userinfo_endpoint,
                    headers={"Authorization": f"Bearer {token_data['access_token']}"}
                )
                
                if userinfo_response.status_code != 200:
                    raise AuthError("invalid_grant", "Failed to get user info")
                
                userinfo = userinfo_response.json()
                user_email = userinfo["email"]
                
                # Check if user exists
                user_repo = p8.repository(User)
                users = user_repo.select(email=user_email)
                
                if not users:
                    # Check if we should allow new users (default: False)
                    allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
                    
                    if not allow_new_users:
                        raise AuthError(
                            "unauthorized",
                            f"User {user_email} is not authorized to access this system. "
                            "Please contact your administrator to request access."
                        )
                
                # Store user with token (only updates if user exists, or creates if allowed)
                await store_user_with_token(
                    email=user_email,
                    username=userinfo.get("name", user_email),
                    token=token_data,
                    session_id=secrets.token_urlsafe(32)
                )
                
                return TokenResponse(
                    access_token=token_data["access_token"],
                    token_type="Bearer",
                    expires_in=token_data.get("expires_in", 3600),
                    refresh_token=token_data.get("refresh_token"),
                    id_token=token_data.get("id_token"),
                    scope=token_data.get("scope", "openid email profile")
                )
        
        elif request.grant_type == "refresh_token":
            return await self.refresh(request.refresh_token)
        
        else:
            raise AuthError("unsupported_grant_type", f"Grant type {request.grant_type} not supported")
    
    async def validate(self, token: str) -> TokenInfo:
        """
        Validate Google access token
        """
        # Try to decode as JWT first
        try:
            # For Google tokens, we can decode without verification for basic info
            # In production, verify against Google's JWKS
            payload = jwt.decode(token, options={"verify_signature": False})
            
            return TokenInfo(
                active=True,
                username=payload.get("name"),
                email=payload.get("email"),
                sub=payload.get("sub"),
                client_id=payload.get("azp") or payload.get("aud"),
                scope=payload.get("scope", "openid email profile"),
                exp=payload.get("exp"),
                iat=payload.get("iat"),
                iss=payload.get("iss"),
                provider="google"
            )
        except jwt.DecodeError:
            # Not a JWT, try token introspection
            async with httpx.AsyncClient() as client:
                response = await client.get(
                    f"https://oauth2.googleapis.com/tokeninfo?access_token={token}"
                )
                
                if response.status_code != 200:
                    raise InvalidTokenError("Invalid Google token")
                
                token_info = response.json()
                
                return TokenInfo(
                    active=True,
                    email=token_info.get("email"),
                    sub=token_info.get("sub"),
                    client_id=token_info.get("azp"),
                    scope=token_info.get("scope"),
                    exp=int(token_info.get("exp", 0)),
                    provider="google"
                )
    
    async def refresh(self, refresh_token: str) -> TokenResponse:
        """
        Refresh Google access token
        """
        async with httpx.AsyncClient() as client:
            response = await client.post(
                self.token_endpoint,
                data={
                    "refresh_token": refresh_token,
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "grant_type": "refresh_token"
                }
            )
            
            if response.status_code != 200:
                error_data = response.json()
                raise AuthError(
                    error_data.get("error", "invalid_grant"),
                    error_data.get("error_description", "Failed to refresh token")
                )
            
            token_data = response.json()
            
            return TokenResponse(
                access_token=token_data["access_token"],
                token_type="Bearer",
                expires_in=token_data.get("expires_in", 3600),
                refresh_token=token_data.get("refresh_token", refresh_token),
                scope=token_data.get("scope", "openid email profile")
            )
    
    async def revoke(self, token: str) -> bool:
        """
        Revoke Google token
        """
        async with httpx.AsyncClient() as client:
            response = await client.post(
                "https://oauth2.googleapis.com/revoke",
                data={"token": token}
            )
            
            return response.status_code == 200


class GoogleOAuthRelayProvider(GoogleOAuthProvider):
    """
    Google OAuth provider in relay mode - doesn't store tokens
    Only registers user email for identification
    """
    
    def __init__(self, client_id: str, client_secret: str, redirect_uri: str):
        super().__init__(client_id, client_secret, redirect_uri)
        self.relay_mode = True
    
    async def token(self, request: TokenRequest) -> TokenResponse:
        """
        Exchange Google authorization code for tokens
        In relay mode, we don't store tokens, only register the user
        """
        if request.grant_type == "authorization_code":
            # Exchange code with Google
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    self.token_endpoint,
                    data={
                        "code": request.code,
                        "client_id": self.client_id,
                        "client_secret": self.client_secret,
                        "redirect_uri": request.redirect_uri or self.redirect_uri,
                        "grant_type": "authorization_code",
                        "code_verifier": request.code_verifier
                    }
                )
                
                if response.status_code != 200:
                    error_data = response.json()
                    raise AuthError(
                        error_data.get("error", "invalid_grant"),
                        error_data.get("error_description", "Failed to exchange code")
                    )
                
                token_data = response.json()
                
                # Get user info
                userinfo_response = await client.get(
                    self.userinfo_endpoint,
                    headers={"Authorization": f"Bearer {token_data['access_token']}"}
                )
                
                if userinfo_response.status_code != 200:
                    raise AuthError("invalid_grant", "Failed to get user info")
                
                userinfo = userinfo_response.json()
                
                # In relay mode: only register user email, don't store tokens
                user_email = userinfo["email"]
                user_name = userinfo.get("name", user_email)
                
                # Check if user exists
                user_repo = p8.repository(User)
                users = user_repo.select(email=user_email)
                
                if not users:
                    # Check if we should allow new users (default: False)
                    allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
                    
                    if not allow_new_users:
                        raise AuthError(
                            "unauthorized",
                            f"User {user_email} is not authorized to access this system. "
                            "Please contact your administrator to request access."
                        )
                    
                    # Only create user if explicitly allowed - new users get default role_level=100
                    user_id = make_uuid(user_email)
                    user = User(
                        id=user_id,
                        name=user_name,
                        email=user_email,
                        role_level=100,  # Default public level for new users
                        groups=["oauth_users"]
                    )
                    user_repo.upsert_records(user)
                else:
                    # User exists - preserve their existing data but update name if changed
                    existing_user = User(**users[0])
                    if existing_user.name != user_name:
                        existing_user.name = user_name
                        user_repo.update_records(existing_user)
                
                # Return tokens directly from Google (not storing them)
                return TokenResponse(
                    access_token=token_data["access_token"],
                    token_type="Bearer",
                    expires_in=token_data.get("expires_in", 3600),
                    refresh_token=token_data.get("refresh_token"),
                    id_token=token_data.get("id_token"),
                    scope=token_data.get("scope", "openid email profile")
                )
        
        elif request.grant_type == "refresh_token":
            return await self.refresh(request.refresh_token)
        
        else:
            raise AuthError("unsupported_grant_type", f"Grant type {request.grant_type} not supported")
    
    async def validate(self, token: str) -> TokenInfo:
        """
        Validate Google access token against Google's servers
        In relay mode, we always check with Google, not local DB
        """
        # Always validate against Google
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"https://oauth2.googleapis.com/tokeninfo?access_token={token}"
            )
            
            if response.status_code != 200:
                # Token expired or invalid
                error_data = response.json()
                if "error" in error_data and error_data["error"] == "invalid_token":
                    # Check if it's specifically an expired token
                    if "error_description" in error_data and "expired" in error_data["error_description"].lower():
                        raise TokenExpiredError("Token has expired")
                raise InvalidTokenError("Invalid Google token")
            
            token_info = response.json()
            
            # Get user from database by email
            user_email = token_info.get("email")
            if user_email:
                user_repo = p8.repository(User)
                users = user_repo.select(email=user_email)
                
                if users:
                    user = User(**users[0])
                    return TokenInfo(
                        active=True,
                        email=user_email,
                        sub=str(user.id),
                        client_id=token_info.get("azp"),
                        scope=token_info.get("scope"),
                        exp=int(token_info.get("exp", 0)),
                        provider="google",
                        metadata={
                            "user_id": str(user.id),
                            "role_level": user.role_level,
                            "groups": user.groups or []
                        }
                    )
            
            # Return basic token info even if user not in DB
            return TokenInfo(
                active=True,
                email=user_email,
                sub=token_info.get("sub"),
                client_id=token_info.get("azp"),
                scope=token_info.get("scope"),
                exp=int(token_info.get("exp", 0)),
                provider="google"
            )