"""Auth utility functions for token and user management"""

import jwt
from datetime import datetime, timedelta,timezone
from percolate.utils import logger
from percolate.models import User
import percolate as p8
from percolate.utils import make_uuid
import typing
from percolate.services import PostgresService
import os
import uuid
from pathlib import Path
import json
from typing import Optional


def decode_jwt_token(jwt_token: str) -> dict:
    """
    Decode a JWT token without verification (for development use).
    In production, this should verify the token signature.
    
    Args:
        jwt_token: The JWT token to decode
        
    Returns:
        The decoded token payload
    """
    try:
        # Check if it's actually a JWT token (should have 3 parts separated by dots)
        if not jwt_token or not isinstance(jwt_token, str) or jwt_token.count('.') != 2:
            logger.debug(f"Invalid JWT format: {jwt_token[:50]}..." if jwt_token else "Empty token")
            return {}
            
        # For development, decode without verification
        # In production, use proper verification with the Google public key
        decoded = jwt.decode(jwt_token, options={"verify_signature": False})
        return decoded
    except jwt.InvalidTokenError as e:
        logger.error(f"Invalid JWT token: {str(e)}")
        return {}
    except UnicodeDecodeError as e:
        logger.error(f"Unicode decode error in JWT: {str(e)}")
        return {}
    except Exception as e:
        logger.error(f"Error decoding JWT token: {str(e)}")
        return {}


def extract_token_expiry(token: typing.Union[str, dict]) -> typing.Optional[datetime]:
    """
    Extract the expiry datetime from a token.
    
    Args:
        token: Either a JWT token string or a dict containing token data
        
    Returns:
        The expiry datetime if found, None otherwise
    """
    if isinstance(token, str):
        # JWT ID token - decode it
        decoded = decode_jwt_token(token)
        exp_timestamp = decoded.get("exp")
    else:
        # Token dict from OAuth response
        if "id_token" in token:
            decoded = decode_jwt_token(token["id_token"])
            exp_timestamp = decoded.get("exp")
        else:
            # Check for expires_at in the OAuth response
            if "expires_at" in token:
                exp_timestamp = token["expires_at"]
            elif "expires_in" in token:
                # Calculate expiry from expires_in
                exp_timestamp = datetime.utcnow().timestamp() + token["expires_in"]
            else:
                exp_timestamp = None
    
    # Convert timestamp to datetime
    if exp_timestamp:
        try:
            return datetime.fromtimestamp(exp_timestamp)
        except (ValueError, TypeError):
            logger.error(f"Invalid expiry timestamp: {exp_timestamp}")
    
    return None


def extract_user_info_from_token(token: typing.Union[str, dict]) -> tuple[str, str, str]:
    """
    Extract user information from either a JWT token string or token dict.
    
    Args:
        token: Either a JWT token string or a dict containing token data
        
    Returns:
        A tuple of (user_id, email, username)
    """
    if isinstance(token, str):
        # JWT ID token - decode it
        decoded = decode_jwt_token(token)
    else:
        # Token dict from OAuth response - extract id_token and decode
        id_token = token.get("id_token", "")
        if id_token:
            decoded = decode_jwt_token(id_token)
        else:
            # Fallback to userinfo if available
            decoded = token.get("userinfo", {})
    
    email = decoded.get("email", "")
    username = decoded.get("name", "") or decoded.get("given_name", "")
    user_id = make_uuid(email) if email else None
    
    return user_id, email, username


def store_user_with_token(token: typing.Union[str, dict], session_id:str, token_expiry: datetime = None) -> User:
    """
    Create or update user with the provided token.
    
    Args:
        token: Either a JWT token string or the full OAuth token dict
        token_expiry: Optional expiry datetime for the token
        
    Returns:
        The created or updated User object
    """
    user_id, email, username = extract_user_info_from_token(token)
    
    if not email:
        logger.error("No email found in token")
        return None
    
    # Extract expiry from token if not provided
    if not token_expiry:
        token_expiry = extract_token_expiry(token)
    
    # If still no expiry, set it to 30 days from now as fallback
    if not token_expiry:
        token_expiry = datetime.now(timezone.utc) + timedelta(days=30)
        logger.warning(f"No expiry found in token for {email}, using default 30-day expiry")
    else:
        logger.info(f"Token for {email} expires at {token_expiry}")
    
    # Store the full token dict if available, otherwise just the string
    # Convert to JSON string since the User model has a string token field
    if isinstance(token, dict):
        import json
        token_to_store = json.dumps(token)
    else:
        token_to_store = token
    
    repo = p8.repository(User)
    
    user = User(
        id=user_id,
        email=email,
        session_id=session_id,
        name=username,  # User model uses 'name' not 'username'
        token=token_to_store,
        token_expiry=token_expiry
    )
    
    repo.update_records(user)
    
    return user


def is_valid_token_for_user(email: str) -> bool:
    """
    Check if the user has a valid (non-expired) token.
    
    Args:
        email: The user's email address
        
    Returns:
        True if the user has a valid token, False otherwise
    """
    try:
        pg = PostgresService()
        
        query = """
            SELECT token, token_expiry
            FROM p8."User"
            WHERE email = %s
            AND token IS NOT NULL
            AND token_expiry > NOW()
        """
        
        result = pg.execute(query,data=(email,))
        
        # If we get a result, the token is valid
        if len(result) > 0:
            # Additionally, we could verify the token itself is still valid
            # by checking its internal expiry
            token = result[0]['token']
            if token:
                try:
                    import json
                    # Try to parse as JSON in case it's a stored dict
                    if token.startswith('{'):
                        token_dict = json.loads(token)
                    else:
                        token_dict = {"id_token": token}
                    
                    # Check the token's internal expiry
                    actual_expiry = extract_token_expiry(token_dict)
                    if actual_expiry and actual_expiry > datetime.utcnow():
                        return True
                    else:
                        logger.warning(f"Token for {email} has expired internally")
                        return False
                except json.JSONDecodeError:
                    # If it's not JSON, treat it as a simple token string
                    pass
            return True
        
        return False
        
    except Exception as e:
        logger.error(f"Error checking token validity for {email}: {str(e)}")
        return False


def get_user_from_email(email: str) -> typing.Optional[User]:
    """
    Get a user by their email address.
    
    Args:
        email: The user's email address
        
    Returns:
        The User object if found, None otherwise
    """
    try:
        repo = p8.repository(User)
        user_id = make_uuid(email)
        
        # select returns a list, so we need to get the first item
        users = repo.select(id=user_id)
        if users and len(users) > 0:
            return users[0]
        return None
    except Exception as e:
        logger.error(f"Error getting user by email {email}: {str(e)}")
        return None


# Session key management for stable sessions
def get_session_key_path() -> Path:
    """Get the path to the session key file"""
    # Store in home directory under .percolate/session_key
    base_path = Path.home() / '.percolate' / 'auth'
    base_path.mkdir(parents=True, exist_ok=True)
    return base_path / 'session_key.json'


def load_session_key() -> Optional[str]:
    """
    Load the session key from file or environment variable.
    
    Returns:
        The session key if found, None otherwise
    """
    # First check environment variable
    env_key = os.environ.get('P8_SESSION_KEY')
    if env_key:
        logger.info("Using session key from environment variable")
        return env_key
    
    # Then check file
    key_path = get_session_key_path()
    if key_path.exists():
        try:
            with open(key_path, 'r') as f:
                data = json.load(f)
                key = data.get('session_key')
                if key:
                    logger.info("Loaded session key from file")
                    return key
        except Exception as e:
            logger.error(f"Error loading session key from file: {e}")
    
    return None


def generate_session_key() -> str:
    """
    Generate a new session key and save it to file.
    
    Returns:
        The generated session key
    """
    # Generate a new key
    key = str(uuid.uuid4())
    
    # Save to file
    key_path = get_session_key_path()
    try:
        with open(key_path, 'w') as f:
            json.dump({
                'session_key': key,
                'created_at': str(uuid.uuid1())
            }, f, indent=2)
        
        # Set restrictive permissions
        os.chmod(key_path, 0o600)
        
        logger.info(f"Generated new session key and saved to {key_path}")
    except Exception as e:
        logger.error(f"Error saving session key: {e}")
    
    return key


def get_stable_session_key() -> str:
    """
    Get a stable session key for the SessionMiddleware.
    
    This ensures session persistence across server restarts by:
    1. Checking for a key in environment variable P8_SESSION_KEY
    2. Loading from ~/.percolate/auth/session_key.json if exists
    3. Generating and saving a new key if needed
    
    Returns:
        A stable session key
    """
    # Try to load existing key
    key = load_session_key()
    
    # If no key exists, generate one
    if not key:
        key = generate_session_key()
    
    return key