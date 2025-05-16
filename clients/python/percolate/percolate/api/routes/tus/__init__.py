"""
Tus upload endpoints configuration and utilities.
"""

from fastapi import Request
from typing import Optional


async def get_project_name(request: Request) -> str:
    """
    Get the project name from the request or use default.
    
    Args:
        request: The FastAPI request object
        
    Returns:
        The project name
    """
    # For now, just use a default project name
    # Later this could come from the session or a header
    return "default"

# Export route components
from .router import router