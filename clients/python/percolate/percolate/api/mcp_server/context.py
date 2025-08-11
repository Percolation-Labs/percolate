"""Context management for MCP requests"""

import contextlib
from contextvars import ContextVar
from typing import Optional, Dict, Any, Callable
import logging

logger = logging.getLogger(__name__)

# Context variable to store auth context for the current request
_auth_context: ContextVar[Optional[Dict[str, Any]]] = ContextVar('mcp_auth_context', default=None)


def get_current_auth_context() -> Optional[Dict[str, Any]]:
    """Get the current auth context from the context variable"""
    return _auth_context.get()


@contextlib.contextmanager
def set_auth_context(auth_context: Dict[str, Any]):
    """Context manager to set auth context for the current request"""
    token = _auth_context.set(auth_context)
    try:
        logger.debug(f"Set auth context: {auth_context.get('email', 'no email')}")
        yield
    finally:
        _auth_context.reset(token)


def create_repository_with_context():
    """Create repository using current auth context"""
    from .repository_factory import create_repository
    
    auth_context = get_current_auth_context()
    if auth_context:
        logger.info(f"✅ MCP Context Flow: Creating repository with auth context for: {auth_context.get('email', 'unknown')}")
        logger.info(f"✅ MCP Context Flow: Token present: {'Yes' if auth_context.get('token') else 'No'}")
        return create_repository(auth_context=auth_context)
    else:
        logger.warning("⚠️  MCP Context Flow: Creating repository with default context (no auth context found)")
        return create_repository()


class ContextAwareRepositoryFactory:
    """Factory that creates repositories with current request context"""
    
    def __call__(self) -> 'BaseMCPRepository':
        return create_repository_with_context()


# Global instance to use in tools
repository_factory = ContextAwareRepositoryFactory()