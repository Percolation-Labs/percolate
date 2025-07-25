"""Factory for creating repository instances based on configuration"""

from typing import Optional, Dict, Any
from .base_repository import BaseMCPRepository
from .database_repository import DatabaseRepository
from .api_repository import APIProxyRepository
from .config import settings
from percolate.utils import logger


def create_repository(
    auth_context: Optional[Dict[str, Any]] = None,
    **kwargs
) -> BaseMCPRepository:
    """Create a repository instance based on configuration.
    
    Args:
        auth_context: Authentication context from MCP request containing:
            - token: Bearer token from Authorization header
            - headers: Additional headers (X-User-Email, etc.)
        **kwargs: Additional arguments for database repository
        
    Returns:
        Repository instance (either DatabaseRepository or APIProxyRepository)
    """
    # Simple decision: API mode is default, database mode requires explicit opt-out
    import os
    use_api_mode = os.getenv("P8_USE_API_MODE", "true").lower() != "false"
    
    if use_api_mode:
        # API mode - extract auth info with fallbacks
        token = None
        user_email = None
        headers = {}
        
        if auth_context:
            token = auth_context.get("token")
            headers = auth_context.get("headers", {})
            user_email = headers.get("X-User-Email")
        
        # Fallback to environment variables
        if not token:
            import os
            # Try P8_API_KEY first, then P8_PG_PASSWORD
            token = os.getenv("P8_API_KEY") or os.getenv("P8_PG_PASSWORD", "postgres")
            
        if not user_email:
            user_email = settings.user_email
        
        logger.info(f"Using API proxy mode with endpoint: {settings.api_endpoint}")
        return APIProxyRepository(
            api_endpoint=settings.api_endpoint,
            api_key=token,
            user_email=user_email,
            additional_headers=headers
        )
    else:
        # Database mode - use provided kwargs or defaults from settings
        logger.info("Using direct database mode")
        return DatabaseRepository(
            user_id=kwargs.get("user_id", settings.user_id),
            user_groups=kwargs.get("user_groups", settings.user_groups),
            role_level=kwargs.get("role_level", settings.role_level),
            user_email=kwargs.get("user_email", settings.user_email)
        )