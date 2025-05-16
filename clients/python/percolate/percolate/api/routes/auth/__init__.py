"""
auth can be bearer token or user sessions


# Using bearer token
curl -X POST http://localhost:5000/auth/ping \
  -H "Authorization: Bearer YOUR_API_KEY" 

# Using session token (after Google login)
curl -X POST http://localhost:5000/auth/ping \
  -H "Cookie: session=..." 

"""


from fastapi import Depends, FastAPI, Header, HTTPException, UploadFile, Request

from typing import Annotated, List
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from percolate.utils.env import load_db_key, POSTGRES_PASSWORD
from percolate.utils import logger
import typing
from .utils import get_user_from_email, is_valid_token_for_user, extract_user_info_from_token


bearer = HTTPBearer(auto_error=False)


"""
Playing with different keys here. The TOKEN should be strict as its a master key
The other token is softer and it can be used to confirm comms between the database and the API but we dont necessarily want to store the master key in the same place.

"""

async def get_api_key(
    credentials: HTTPAuthorizationCredentials = Depends(bearer),
):
    token = credentials.credentials

    """we should allow the API_TOKEN which can be lower security i.e. allow some users to use without providing keys to the castle"""
    """TODO single and multi ten auth"""
    key = load_db_key('P8_API_KEY')
    if token != key and token != POSTGRES_PASSWORD:
        logger.warning(f"Failing to connect using token {token[:3]}..{token[-3:]} - expecting either {key[:3]}..{key[-3:]} or {POSTGRES_PASSWORD[:3]}..{POSTGRES_PASSWORD[-3:]}")
        raise HTTPException(
            status_code=401,
            detail="Invalid API KEY in token check.",
        )

    return token


def get_current_token(
    credentials: HTTPAuthorizationCredentials = Depends(bearer),
):
    token = credentials.credentials

    """we should allow the API_TOKEN which can be lower security i.e. allow some users to use without providing keys to the castle"""
    """TODO single and multi ten auth"""
    
    #print('compare', token, POSTGRES_PASSWORD) -> prints are not logged k8s and good for debugging
    
    if token != POSTGRES_PASSWORD:
        raise HTTPException(
            status_code=401,
            detail="Invalid API KEY in token check.",
        )

    return token


def get_user_from_session(request: Request) -> typing.Optional[str]:
    """
    Extract the user ID from the session.
    
    Args:
        request: The FastAPI request object
        
    Returns:
        The user ID if available, None otherwise
    """
    try:
        logger.debug(f"Session keys: {list(request.session.keys())}")
        # Try to get user info from the session
        if 'token' in request.session:
            logger.debug("Token found in session")
            token = request.session['token']
            user_id, email, username = extract_user_info_from_token(token)
            logger.debug(f"Extracted: user_id={user_id}, email={email}, username={username}")
            
            if email:
                # Look up the user by email to get the percolate user ID
                user = get_user_from_email(email)
                if user:
                    logger.debug(f"Found user ID in session: {user['id']} for email: {email}")
                    return str(user['id'])
                else:
                    logger.debug(f"No user found for email: {email}")
    except Exception as e:
        logger.error(f"Error getting user from session: {str(e)}")
    
    return None

def get_user_id(
    request: Request,
    authorization: typing.Optional[HTTPAuthorizationCredentials] = Depends(bearer)
) -> typing.Optional[str]:
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

# Hybrid authentication classes that support both bearer token and session auth
class HybridAuth:
    """
    Dependency class that supports both bearer token and session authentication.
    - Bearer token: Valid API key allows access without user context (for testing/API access)
    - Session: Extracts user_id from session for logged-in users
    """
    
    async def __call__(
        self, 
        request: Request,
        credentials: typing.Optional[HTTPAuthorizationCredentials] = Depends(bearer)
    ) -> typing.Optional[str]:
        """
        Returns user_id if session auth is used, None if bearer token is used.
        Raises 401 if neither authentication method is valid.
        """
        
        # Debug logging
        session_cookie = request.cookies.get('session')
        session_keys = list(request.session.keys()) if hasattr(request, 'session') else []
        logger.debug(f"HybridAuth - Session cookie present: {bool(session_cookie)}")
        logger.debug(f"HybridAuth - Session keys: {session_keys}")
        logger.debug(f"HybridAuth - Bearer token present: {bool(credentials)}")
        
        # First, try session authentication
        try:
            user_id = get_user_from_session(request)
            if user_id:
                logger.debug(f"Authenticated via session: user_id={user_id}")
                return user_id
        except Exception as e:
            logger.debug(f"Session auth failed: {e}")
        
        # If no session, try bearer token
        if credentials:
            try:
                # Validate the bearer token
                await get_api_key(credentials)
                logger.debug("Authenticated via bearer token (no user context)")
                return None  # Valid bearer token but no user context
            except HTTPException:
                logger.debug("Bearer token validation failed")
        
        # If both methods fail, raise 401
        raise HTTPException(
            status_code=401,
            detail="Authentication required. Use session login or valid API key.",
            headers={"WWW-Authenticate": "Bearer"}
        )


# Create singleton instances for different use cases
hybrid_auth = HybridAuth()  # Returns Optional[str] - None for bearer, user_id for session


class RequireUserAuth(HybridAuth):
    """
    Variant that requires user context (session only, no bearer tokens).
    """
    
    async def __call__(
        self, 
        request: Request,
        credentials: typing.Optional[HTTPAuthorizationCredentials] = Depends(bearer)
    ) -> str:
        user_id = await super().__call__(request, credentials)
        if user_id is None:
            raise HTTPException(
                status_code=401,
                detail="User authentication required. API keys not accepted for this endpoint."
            )
        return user_id


require_user_auth = RequireUserAuth()


def get_session_user_id(request: Request) -> str:
    """
    Get the user ID from the session. Raises 401 if not logged in.
    
    Args:
        request: The FastAPI request object
        
    Returns:
        The user ID if logged in
        
    Raises:
        HTTPException: 401 if user is not logged in
    """
    user_id = get_user_from_session(request)
    if not user_id:
        raise HTTPException(
            status_code=401,
            detail="Authentication required. Please login first.",
        )
    return user_id


def get_optional_session_user_id(request: Request) -> typing.Optional[str]:
    """
    Get the user ID from the session if available.
    
    Args:
        request: The FastAPI request object
        
    Returns:
        The user ID if logged in, None otherwise
    """
    return get_user_from_session(request)


from .router import router