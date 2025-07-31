"""Factory for creating repository instances based on configuration"""

from typing import Optional, Dict, Any
from .base_repository import BaseMCPRepository
from .api_repository import APIProxyRepository
from .config import settings
import logging

logger = logging.getLogger(__name__)


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
            # Try P8_TEST_BEARER_TOKEN first, then P8_API_KEY, then P8_PG_PASSWORD
            token = os.getenv("P8_TEST_BEARER_TOKEN") or os.getenv("P8_API_KEY") or os.getenv("P8_PG_PASSWORD", "postgres")
            
        if not user_email:
            user_email = settings.user_email
        
        # Don't pass api_endpoint if we want to use environment variables
        # Only pass token if we found one (don't pass empty string)
        logger.info(f"Using API proxy mode")
        return APIProxyRepository(
            api_endpoint=None,  # Let APIProxyRepository read from environment
            api_key=token if token else None,  # Only pass if we have a value
            user_email=user_email if user_email else None,
            additional_headers=headers
        )
    else:
        # Database mode - lazy import to avoid dependency issues in DXT
        try:
            from .database_repository import DatabaseRepository
            logger.info("Using direct database mode")
            return DatabaseRepository(
                user_id=kwargs.get("user_id", settings.user_id),
                user_groups=kwargs.get("user_groups", settings.user_groups),
                role_level=kwargs.get("role_level", settings.role_level),
                user_email=kwargs.get("user_email", settings.user_email)
            )
        except ImportError as e:
            logger.warning(f"Database mode requested but dependencies not available: {e}")
            logger.info("Falling back to API proxy mode")
            # Fallback to API mode
            token = None
            user_email = None
            headers = {}
            
            if auth_context:
                token = auth_context.get("token")
                headers = auth_context.get("headers", {})
                user_email = headers.get("X-User-Email")
            
            if not token:
                import os
                token = os.getenv("P8_TEST_BEARER_TOKEN") or os.getenv("P8_API_KEY") or os.getenv("P8_PG_PASSWORD", "postgres")
                
            if not user_email:
                user_email = settings.user_email
            
            return APIProxyRepository(
                api_endpoint=settings.api_endpoint,
                api_key=token,
                user_email=user_email,
                additional_headers=headers
            )