"""Integration helpers for mounting MCP server in the main API"""

from typing import Optional
from fastapi import FastAPI, Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from fastapi.responses import JSONResponse
import logging
import os
from .server import create_mcp_server
from .config import get_mcp_settings

logger = logging.getLogger(__name__)


class MCPAuthMiddleware(BaseHTTPMiddleware):
    """Authentication middleware for MCP endpoints"""
    
    def __init__(self, app, settings):
        super().__init__(app)
        self.settings = settings
        
    async def dispatch(self, request: Request, call_next):
        # Only apply auth to MCP endpoints
        if not request.url.path.startswith('/mcp'):
            return await call_next(request)
            
        # Skip auth for MCP protocol initialization
        if request.method == 'POST':
            body = await request.body()
            # Allow initialize and tools/list without auth for protocol setup
            if b'"method":"initialize"' in body or b'"method":"tools/list"' in body:
                request._body = body
                return await call_next(request)
            request._body = body  # Restore body for downstream processing
        
        # Check for bearer token
        auth_header = request.headers.get('Authorization')
        
        if not auth_header or not auth_header.startswith('Bearer '):
            return JSONResponse(
                status_code=401, 
                content={"error": "Bearer token required"}
            )
        
        token = auth_header[7:]  # Remove 'Bearer ' prefix
        
        # Basic token validation
        if not token or len(token) < 10:
            return JSONResponse(
                status_code=401, 
                content={"error": "Invalid bearer token"}
            )
        
        # Extract user email from token or use a default approach
        user_email = None
        
        # Try to extract user email from JWT token first (proper OAuth approach)
        user_email = self._extract_email_from_token(token)
        
        # Fallback: check X-User-Email header (for testing/development)
        if not user_email:
            user_email = request.headers.get('X-User-Email')
            
        # Final fallback: use configured email from MCP settings
        if not user_email:
            from .config import get_mcp_settings
            settings = get_mcp_settings()
            user_email = settings.user_email
            
        # If still no email, use a placeholder (can be enhanced later)
        if not user_email:
            user_email = "mcp-user@unknown"
            logger.warning("No user email found in token, headers, or settings - using placeholder")
        
        # Add user context to request state
        request.state.user_email = user_email
        request.state.bearer_token = token
        request.state.user_context = {
            'email': user_email,
            'token': token,
            'authenticated': True
        }
        
        # Store auth context for MCP tools access
        auth_context = {
            'token': token,
            'headers': {
                'X-User-Email': user_email,
                'Authorization': f'Bearer {token}'
            },
            'email': user_email,
            'authenticated': True
        }
        request.state.mcp_auth_context = auth_context
        
        logger.info(f"MCP request authenticated for user: {user_email}")
        
        # Set the auth context for the current request using context variables
        from .context import set_auth_context
        with set_auth_context(auth_context):
            return await call_next(request)
    
    def _extract_email_from_token(self, token: str) -> Optional[str]:
        """Extract email from JWT token if possible"""
        try:
            # Simple JWT decode (without verification for now - just extract claims)
            import base64
            import json
            
            # JWT format: header.payload.signature
            parts = token.split('.')
            if len(parts) >= 2:
                # Decode payload (second part)
                payload = parts[1]
                # Add padding if needed
                payload += '=' * (4 - len(payload) % 4)
                decoded = base64.b64decode(payload)
                claims = json.loads(decoded)
                
                # Try common email claims in order of preference
                email_candidates = [
                    claims.get('email'),
                    claims.get('user_email'), 
                    claims.get('preferred_username'),
                    claims.get('sub') if '@' in str(claims.get('sub', '')) else None
                ]
                
                for email in email_candidates:
                    if email and isinstance(email, str) and '@' in email:
                        logger.debug(f"Extracted email from JWT token: {email}")
                        return email
                
                logger.debug(f"No email found in JWT claims: {list(claims.keys())}")
                
        except Exception as e:
            logger.debug(f"Could not extract email from token: {e}")
            
        return None


def _get_api_key_source(settings) -> str:
    """Helper to identify which environment variable provided the API key"""
    if os.getenv('P8_PG_PASSWORD') and os.getenv('P8_PG_PASSWORD') == settings.api_key:
        return "P8_PG_PASSWORD"
    elif os.getenv('P8_API_KEY') and os.getenv('P8_API_KEY') == settings.api_key:
        return "P8_API_KEY" 
    elif os.getenv('P8_TEST_BEARER_TOKEN') and os.getenv('P8_TEST_BEARER_TOKEN') == settings.api_key:
        return "P8_TEST_BEARER_TOKEN"
    else:
        return "unknown source"


def mount_mcp_server(app: FastAPI, path: str = "/mcp") -> Optional[FastAPI]:
    """
    Mount MCP server on the main FastAPI app.
    
    This should be called after the main app is created but before starting.
    The MCP server will share the app's lifespan.
    
    Args:
        app: The main FastAPI application
        path: Path to mount MCP server (default: /mcp)
        
    Returns:
        The MCP FastAPI app if mounted, None if not configured
    """
    settings = get_mcp_settings()
    
    # Only mount if API key is configured
    if not settings.api_key:
        logger.info("MCP server not mounted - no API key configured (P8_PG_PASSWORD, P8_API_KEY, or P8_TEST_BEARER_TOKEN)")
        return None
    
    try:
        logger.info(f"Creating MCP server with API key from: {_get_api_key_source(settings)}")
        
        # Add authentication middleware to main app for MCP endpoints
        app.add_middleware(MCPAuthMiddleware, settings=settings)
        logger.info("Added MCP authentication middleware for Bearer token + X-User-Email")
        
        # Create MCP server (without FastMCP auth since we handle it in middleware)
        mcp = create_mcp_server()
        
        # FastMCP creates a Starlette app with its own /mcp route
        # We need to mount it in a way that doesn't double-prefix the path
        mcp_app = mcp.http_app()
        
        # Find the actual handler function from the MCP app's routes
        mcp_handler = None
        for route in mcp_app.routes:
            if hasattr(route, 'app') and route.path == '/mcp':
                mcp_handler = route.app
                break
        
        if mcp_handler:
            # Mount the handler function directly at the desired path
            from starlette.routing import Mount
            mount_route = Mount(path, mcp_handler)
            app.router.routes.append(mount_route)
            logger.info(f"MCP handler mounted at {path}")
        else:
            # Fallback: mount the entire app but log the double path issue
            app.mount(path, mcp_app)
            logger.warning(f"MCP server mounted at {path} - endpoints may be at {path}/mcp")
        
        return mcp_app
        
    except Exception as e:
        logger.error(f"Failed to mount MCP server: {e}")
        return None