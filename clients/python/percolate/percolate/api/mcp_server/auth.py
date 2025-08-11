"""Authentication for MCP server using existing Percolate auth patterns"""

from typing import Optional, Dict, Any, Callable
from .config import get_mcp_settings
import httpx
import logging
from starlette.requests import Request
from starlette.responses import JSONResponse

logger = logging.getLogger(__name__)


async def percolate_auth_handler(request: Request) -> Optional[Dict[str, Any]]:
    """FastMCP auth handler that validates bearer tokens
    
    This function is called by FastMCP to validate authentication.
    It extracts the bearer token from the Authorization header and validates it.
    """
    settings = get_mcp_settings()
    
    # Extract bearer token from Authorization header
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return None
        
    token = auth_header[7:]  # Remove "Bearer " prefix
    
    # Extract email from X-User-Email header if provided
    user_email = request.headers.get("X-User-Email", settings.user_email)
    
    # For desktop extension mode, validate against configured tokens
    if settings.is_desktop_extension:
        # Check if it's a configured API key
        if token == settings.api_key:
            if not user_email:
                logger.warning("API key authentication requires email")
                return None
                
            return {
                "user_id": settings.user_id,
                "email": user_email,
                "user_groups": settings.user_groups,
                "role_level": settings.role_level,
                "auth_type": "api_key"
            }
        
        return None
    
    # For server mode, validate against Percolate API
    try:
        headers = {"Authorization": f"Bearer {token}"}
        if user_email:
            headers["X-User-Email"] = user_email
        
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{settings.api_endpoint}/auth/me",
                headers=headers
            )
        
        if response.status_code == 200:
            user_data = response.json()
            return {
                "user_id": user_data.get("id", settings.user_id),
                "email": user_data.get("email", user_email or "api_user@percolate.local"),
                "user_groups": user_data.get("groups", settings.user_groups),
                "role_level": user_data.get("role_level", settings.role_level),
                "auth_type": "api_validated"
            }
            
    except Exception as e:
        logger.error(f"API validation error: {e}")
        
    return None


class FastMCPAuthHandler:
    """FastMCP-compatible authentication handler wrapper"""
    
    def __init__(self, settings):
        self.settings = settings
        self.required_scopes = ["read", "write"]
        self.issuer_url = settings.api_endpoint
    
    async def __call__(self, request) -> Optional[Dict[str, Any]]:
        """Handle authentication - delegates to existing handler"""
        return await percolate_auth_handler(request)
    
    def get_routes(self):
        """Required by FastMCP - return empty routes list"""
        return []
    
    def get_resource_metadata_url(self):
        """Required by FastMCP - return resource metadata URL"""
        return f"{self.settings.api_endpoint}/.well-known/oauth-protected-resource"


def get_auth_handler() -> Optional[Callable]:
    """Get authentication handler if any auth is configured"""
    settings = get_mcp_settings()
    # TODO: Fix FastMCP auth handler compatibility - needs full OAuth interface
    # For now, return None to enable MCP server without auth
    # The auth handler needs to implement the full FastMCP auth protocol
    return None
    
    # Disabled until FastMCP compatibility is fully implemented:
    # if settings.api_key:
    #     return FastMCPAuthHandler(settings)
    # return None