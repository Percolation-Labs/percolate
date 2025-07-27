"""
JWT-based OAuth provider for Percolate (Mode 2)
"""

import os
import jwt
import secrets
import hashlib
import base64
from datetime import datetime, timedelta
from typing import Dict, Any, Optional

import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid
from .providers import AuthProvider
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


class PercolateJWTProvider(AuthProvider):
    """
    Percolate as OAuth provider using JWT tokens
    Initial authorization uses bearer token, then issues JWT access tokens
    """
    
    def __init__(self, jwt_secret: str = None, jwt_algorithm: str = "HS256", 
                 access_token_expiry: int = 3600, refresh_token_expiry: int = 86400 * 30):
        """
        Initialize JWT provider
        
        Args:
            jwt_secret: Secret key for signing JWTs (defaults to env var)
            jwt_algorithm: JWT signing algorithm (default: HS256)
            access_token_expiry: Access token expiry in seconds (default: 1 hour)
            refresh_token_expiry: Refresh token expiry in seconds (default: 30 days)
        """
        self.jwt_secret = jwt_secret or os.getenv("JWT_SECRET") or secrets.token_urlsafe(32)
        self.jwt_algorithm = jwt_algorithm
        self.access_token_expiry = access_token_expiry
        self.refresh_token_expiry = refresh_token_expiry
        self.issuer = os.getenv("PERCOLATE_BASE_URL", "https://api.percolate.ai")
        
        # Temporary storage for auth codes
        self.auth_codes: Dict[str, Dict[str, Any]] = {}
        
    def generate_jwt(self, user: User, token_type: str = "access") -> str:
        """Generate a JWT token for a user"""
        now = datetime.utcnow()
        
        if token_type == "access":
            expiry = now + timedelta(seconds=self.access_token_expiry)
            token_id = secrets.token_urlsafe(16)
        else:  # refresh token
            expiry = now + timedelta(seconds=self.refresh_token_expiry)
            token_id = secrets.token_urlsafe(32)
        
        payload = {
            "sub": str(user.id),
            "email": user.email,
            "name": user.name,
            "role_level": user.role_level,
            "groups": user.groups or [],
            "iat": int(now.timestamp()),
            "exp": int(expiry.timestamp()),
            "iss": self.issuer,
            "aud": "percolate-api",
            "jti": token_id,
            "token_type": token_type
        }
        
        return jwt.encode(payload, self.jwt_secret, algorithm=self.jwt_algorithm)
    
    async def authorize(self, request: AuthRequest) -> AuthResponse:
        """
        Validate bearer token and email, return authorization code
        """
        if not request.bearer_token:
            raise AuthError("invalid_request", "Bearer token required")
        
        if not request.user_email:
            raise AuthError("invalid_request", "X-User-Email header required")
        
        # Validate token exists and belongs to user
        user_repo = p8.repository(User)
        users = user_repo.select(email=request.user_email, token=request.bearer_token)
        
        if not users:
            raise InvalidTokenError("Invalid bearer token for user")
        
        user = User(**users[0])
        
        # Check token expiry
        if user.token_expiry and datetime.utcnow() > user.token_expiry:
            raise TokenExpiredError()
        
        # Generate authorization code
        code = secrets.token_urlsafe(32)
        
        # Store code with metadata for exchange
        self.auth_codes[code] = {
            "client_id": request.client_id,
            "user_id": str(user.id),
            "user_email": user.email,
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
        Exchange authorization code for JWT tokens or refresh JWT token
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
            user_repo = p8.repository(User)
            users = user_repo.select(email=code_data["user_email"])
            
            if not users:
                raise AuthError("invalid_grant", "User not found")
            
            user = User(**users[0])
            
            # Clean up code
            del self.auth_codes[request.code]
            
            # Generate JWT tokens
            access_token = self.generate_jwt(user, "access")
            refresh_token = self.generate_jwt(user, "refresh")
            
            # Store refresh token in database
            user.session_id = refresh_token
            user.last_session_at = datetime.utcnow()
            user_repo.update_records(user)
            
            return TokenResponse(
                access_token=access_token,
                token_type="Bearer",
                expires_in=self.access_token_expiry,
                refresh_token=refresh_token,
                scope="read write"
            )
        
        elif request.grant_type == "refresh_token":
            if not request.refresh_token:
                raise AuthError("invalid_request", "Refresh token required")
            
            try:
                # Decode refresh token
                payload = jwt.decode(
                    request.refresh_token,
                    self.jwt_secret,
                    algorithms=[self.jwt_algorithm],
                    audience="percolate-api",
                    issuer=self.issuer
                )
                
                if payload.get("token_type") != "refresh":
                    raise InvalidTokenError("Not a refresh token")
                
                # Get user
                user_repo = p8.repository(User)
                users = user_repo.select(id=payload["sub"])
                
                if not users:
                    raise InvalidTokenError("User not found")
                
                user = User(**users[0])
                
                # Verify refresh token matches stored session
                if user.session_id != request.refresh_token:
                    raise InvalidTokenError("Invalid refresh token")
                
                # Generate new access token
                access_token = self.generate_jwt(user, "access")
                
                return TokenResponse(
                    access_token=access_token,
                    token_type="Bearer",
                    expires_in=self.access_token_expiry,
                    refresh_token=request.refresh_token,  # Return same refresh token
                    scope="read write"
                )
                
            except jwt.ExpiredSignatureError:
                raise TokenExpiredError("Refresh token expired")
            except jwt.InvalidTokenError as e:
                raise InvalidTokenError(f"Invalid refresh token: {str(e)}")
        
        else:
            raise AuthError("unsupported_grant_type", f"Grant type {request.grant_type} not supported")
    
    async def validate(self, token: str) -> TokenInfo:
        """
        Validate JWT token
        """
        try:
            # Decode and verify JWT
            payload = jwt.decode(
                token,
                self.jwt_secret,
                algorithms=[self.jwt_algorithm],
                audience="percolate-api",
                issuer=self.issuer,
                leeway=10  # 10 second leeway for timing issues
            )
            
            # Check token type
            if payload.get("token_type") not in ["access", None]:
                raise InvalidTokenError("Not an access token")
            
            return TokenInfo(
                active=True,
                username=payload.get("name"),
                email=payload.get("email"),
                sub=payload.get("sub"),
                client_id="percolate-jwt",
                scope="read write",
                exp=payload.get("exp"),
                iat=payload.get("iat"),
                provider="percolate",
                metadata={
                    "user_id": payload.get("sub"),
                    "role_level": payload.get("role_level", 100),
                    "groups": payload.get("groups", [])
                }
            )
            
        except jwt.ExpiredSignatureError:
            raise TokenExpiredError()
        except jwt.InvalidTokenError as e:
            raise InvalidTokenError(f"Invalid JWT: {str(e)}")
    
    async def refresh(self, refresh_token: str) -> TokenResponse:
        """
        Refresh access token using refresh token
        """
        return await self.token(TokenRequest(
            grant_type="refresh_token",
            refresh_token=refresh_token
        ))
    
    async def revoke(self, token: str) -> bool:
        """
        Revoke a token by removing the session
        """
        try:
            # Decode token to get user ID
            payload = jwt.decode(
                token,
                self.jwt_secret,
                algorithms=[self.jwt_algorithm],
                options={"verify_exp": False}  # Allow expired tokens to be revoked
            )
            
            user_id = payload.get("sub")
            if not user_id:
                return False
            
            # Clear session for user
            user_repo = p8.repository(User)
            users = user_repo.select(id=user_id)
            
            if users:
                user = User(**users[0])
                user.session_id = None
                user.last_session_at = None
                user_repo.update_records(user)
                return True
                
        except jwt.InvalidTokenError:
            pass
        
        return False