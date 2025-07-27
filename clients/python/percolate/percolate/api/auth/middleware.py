"""
Authentication middleware for FastAPI
"""

from typing import Optional, List, Callable
from functools import wraps
from fastapi import Request, HTTPException, Depends, Header
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

from .server import OAuthServer
from .models import AuthContext, AuthError, TokenExpiredError, InsufficientScopeError
from percolate.models.p8.types import User
from percolate.utils import logger
import percolate as p8


# Security scheme for OpenAPI
bearer_scheme = HTTPBearer(auto_error=False)


class AuthMiddleware(BaseHTTPMiddleware):
    """
    Authentication middleware that validates tokens on protected routes
    """
    
    def __init__(self, app, oauth_server: OAuthServer, exclude_paths: List[str] = None):
        super().__init__(app)
        self.oauth_server = oauth_server
        self.exclude_paths = exclude_paths or []
        
        # Add default exclude paths
        self.exclude_paths.extend([
            "/docs",
            "/openapi.json",
            "/health",
            "/auth/",
            "/.well-known/",
            "/mcp"  # MCP has its own auth handling
        ])
    
    async def dispatch(self, request: Request, call_next):
        """
        Process request and validate authentication if needed
        """
        # Check if path is excluded
        path = request.url.path
        if any(path.startswith(exclude) for exclude in self.exclude_paths):
            return await call_next(request)
        
        # Extract token
        token = None
        user_email = None
        
        # Check Authorization header
        auth_header = request.headers.get("Authorization")
        if auth_header and auth_header.startswith("Bearer "):
            token = auth_header[7:]
        
        # Check X-User-Email header for bearer token auth
        # Also check X_USER_EMAIL from environment if header not present
        user_email = request.headers.get("X-User-Email")
        if not user_email:
            # Check for environment variable with underscore format
            import os
            user_email = os.environ.get("X_USER_EMAIL")
        
        # If no token, return 401
        if not token:
            return JSONResponse(
                status_code=401,
                content={
                    "error": "unauthorized",
                    "error_description": "Authentication required"
                },
                headers={
                    "WWW-Authenticate": f'Bearer realm="{self.oauth_server.base_url}"'
                }
            )
        
        try:
            # First check if this is an API key (postgres or P8_API_KEY)
            from percolate.utils.env import load_db_key, POSTGRES_PASSWORD
            api_key = load_db_key('P8_API_KEY')
            
            if token == POSTGRES_PASSWORD or token == api_key:
                # This is a valid API key, create auth context
                from percolate.utils import make_uuid
                
                # Use email from header or default
                email = user_email or "api@percolate.ai"
                user_id = make_uuid(email) if user_email else "api_user"
                
                auth_context = AuthContext(
                    user_id=user_id,
                    email=email,
                    provider="bearer",
                    scopes=["api"],
                    token=token,
                    metadata={"api_key": True}
                )
                
                # Store in request state
                request.state.auth = auth_context
                request.state.user_id = user_id
                request.state.user_groups = []
                request.state.role_level = 1  # API keys have full access
                
                # Process request
                response = await call_next(request)
                return response
            
            # Not an API key, validate as OAuth token
            token_info = await self.oauth_server.validate_token(token)
            
            # For bearer tokens, verify email matches
            if token_info.provider == "bearer" and user_email:
                if token_info.email != user_email:
                    raise AuthError("invalid_token", "Token does not match user email")
            
            # Create auth context
            auth_context = AuthContext(
                user_id=token_info.sub or token_info.email,
                email=token_info.email or token_info.username,
                provider=token_info.provider,
                scopes=token_info.scope.split() if token_info.scope else [],
                token=token,
                metadata=token_info.metadata or {}
            )
            
            # Store in request state
            request.state.auth = auth_context
            
            # Set user context for repository operations
            if auth_context.user_id:
                request.state.user_id = auth_context.user_id
                request.state.user_groups = auth_context.metadata.get("groups", [])
                request.state.role_level = auth_context.metadata.get("role_level", 100)
            
        except TokenExpiredError as e:
            return JSONResponse(
                status_code=401,
                content={
                    "error": "token_expired",
                    "error_description": str(e)
                },
                headers={
                    "WWW-Authenticate": 'Bearer error="invalid_token", error_description="Token expired"'
                }
            )
        except AuthError as e:
            return JSONResponse(
                status_code=e.status_code,
                content={
                    "error": e.error,
                    "error_description": e.error_description
                },
                headers={
                    "WWW-Authenticate": f'Bearer error="{e.error}"'
                }
            )
        except Exception as e:
            logger.error(f"Authentication error: {e}")
            return JSONResponse(
                status_code=500,
                content={
                    "error": "server_error",
                    "error_description": "Authentication failed"
                }
            )
        
        # Process request
        response = await call_next(request)
        return response


async def get_auth(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    x_user_email: Optional[str] = Header(None)
) -> AuthContext:
    """
    Dependency to get authentication context
    """
    # Check if already authenticated by middleware
    if hasattr(request.state, "auth"):
        return request.state.auth
    
    # Check for X_USER_EMAIL env var if header not provided
    if not x_user_email:
        import os
        x_user_email = os.environ.get("X_USER_EMAIL")
    
    # Manual authentication for routes not covered by middleware
    if not credentials:
        raise HTTPException(
            status_code=401,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"}
        )
    
    # Get OAuth server from app state
    oauth_server = request.app.state.oauth_server
    
    try:
        # Validate token
        token_info = await oauth_server.validate_token(credentials.credentials)
        
        # For bearer tokens, verify email matches
        if token_info.provider == "bearer" and x_user_email:
            if token_info.email != x_user_email:
                raise HTTPException(
                    status_code=401,
                    detail="Token does not match user email"
                )
        
        # Create auth context
        return AuthContext(
            user_id=token_info.sub or token_info.email,
            email=token_info.email or token_info.username,
            provider=token_info.provider,
            scopes=token_info.scope.split() if token_info.scope else [],
            token=credentials.credentials,
            metadata=token_info.metadata or {}
        )
        
    except TokenExpiredError:
        raise HTTPException(
            status_code=401,
            detail="Token expired",
            headers={"WWW-Authenticate": 'Bearer error="invalid_token"'}
        )
    except AuthError as e:
        raise HTTPException(
            status_code=e.status_code,
            detail=e.error_description or e.error,
            headers={"WWW-Authenticate": f'Bearer error="{e.error}"'}
        )
    except Exception as e:
        logger.error(f"Authentication error: {e}")
        raise HTTPException(
            status_code=500,
            detail="Authentication failed"
        )


def require_auth(scopes: Optional[List[str]] = None):
    """
    Decorator to require authentication with optional scope checking
    
    Usage:
        @app.get("/protected")
        @require_auth()
        async def protected_route(auth: AuthContext = Depends(get_auth)):
            return {"user": auth.email}
        
        @app.get("/admin")
        @require_auth(scopes=["admin"])
        async def admin_route(auth: AuthContext = Depends(get_auth)):
            return {"admin": True}
    """
    def decorator(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            # Get auth context from kwargs
            auth = kwargs.get("auth")
            if not auth:
                # Try to find it in args (for class methods)
                for arg in args:
                    if isinstance(arg, AuthContext):
                        auth = arg
                        break
            
            if not auth:
                raise HTTPException(
                    status_code=401,
                    detail="Authentication required"
                )
            
            # Check scopes if required
            if scopes:
                if not auth.has_any_scope(scopes):
                    raise InsufficientScopeError(f"Required scopes: {', '.join(scopes)}")
            
            return await func(*args, **kwargs)
        
        return wrapper
    return decorator


async def get_current_user(auth: AuthContext = Depends(get_auth)) -> User:
    """
    Dependency to get the current user object
    """
    user_repo = p8.repository(User)
    users = user_repo.select(email=auth.email)
    
    if not users:
        raise HTTPException(status_code=404, detail="User not found")
    
    return User(**users[0])


# Optional dependencies for different authentication scenarios
async def optional_auth(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    x_user_email: Optional[str] = Header(None)
) -> Optional[AuthContext]:
    """
    Optional authentication - returns None if not authenticated
    """
    try:
        return await get_auth(request, credentials, x_user_email)
    except HTTPException:
        return None


async def require_admin(auth: AuthContext = Depends(get_auth)) -> AuthContext:
    """
    Require admin role
    """
    if not auth.has_scope("admin") and auth.metadata.get("role_level", 100) > 1:
        raise HTTPException(
            status_code=403,
            detail="Admin access required"
        )
    return auth