"""
Authentication and authorization utilities for the Tus upload endpoints.
"""

from fastapi import Depends, Header, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.middleware.sessions import SessionMiddleware
from typing import Optional
from percolate.utils import logger
from percolate.api.routes.auth import get_api_key, get_current_token

# Initialize the HTTP bearer scheme
bearer = HTTPBearer(auto_error=False)

def get_user_from_session(request: Request) -> Optional[str]:
    """
    Extract the user ID from the session.
    
    Args:
        request: The FastAPI request object
        
    Returns:
        The user ID if available, None otherwise
    """
    try:
        # Try to get user info from the session
        if 'token' in request.session and 'userinfo' in request.session['token']:
            userinfo = request.session['token']['userinfo']
            user_id = userinfo.get('sub')
            
            if user_id:
                logger.debug(f"Found user ID in session: {user_id}")
                return user_id
    except Exception as e:
        logger.error(f"Error getting user from session: {str(e)}")
    
    return None

def get_user_id(
    request: Request,
    authorization: Optional[HTTPAuthorizationCredentials] = Depends(bearer)
) -> Optional[str]:
    """
    Get the user ID from either the session or the API key.
    
    Args:
        request: The FastAPI request object
        authorization: Optional authorization credentials
        
    Returns:
        The user ID if available, None otherwise
    """
    # First try to get from session
    user_id = get_user_from_session(request)
    if user_id:
        return user_id
    
    # Return None if no user ID could be determined
    return None

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