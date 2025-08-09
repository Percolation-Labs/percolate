"""
Authentication utility functions
"""

import os
import jwt
import hashlib
from datetime import datetime, timedelta
from typing import Optional, Dict, Any
import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid, logger


def decode_jwt_token(token: str) -> Dict[str, Any]:
    """Decode JWT token without verification (for extracting claims)"""
    try:
        return jwt.decode(token, options={"verify_signature": False})
    except Exception:
        return {}


def extract_token_expiry(token_data: Dict[str, Any]) -> Optional[datetime]:
    """Extract token expiry from decoded token data"""
    if 'exp' in token_data:
        return datetime.fromtimestamp(token_data['exp'])
    elif 'expires_at' in token_data:
        return datetime.fromisoformat(token_data['expires_at'].replace('Z', '+00:00'))
    return None


def extract_user_info_from_token(token_data: Dict[str, Any]) -> Dict[str, Any]:
    """Extract user information from decoded token"""
    user_info = {}
    
    # Standard claims
    if 'email' in token_data:
        user_info['email'] = token_data['email']
    elif 'sub' in token_data and '@' in token_data['sub']:
        user_info['email'] = token_data['sub']
    
    if 'name' in token_data:
        user_info['name'] = token_data['name']
    
    # Google specific
    if 'given_name' in token_data:
        user_info['given_name'] = token_data['given_name']
    if 'family_name' in token_data:
        user_info['family_name'] = token_data['family_name']
    if 'picture' in token_data:
        user_info['picture'] = token_data['picture']
    
    return user_info


def store_user_with_token(email: str, token: str, name: Optional[str] = None, 
                         token_expiry: Optional[datetime] = None,
                         oauth_provider: Optional[str] = None) -> User:
    """Store or update user with token"""
    user_id = make_uuid(email)
    
    user = User(
        id=user_id,
        email=email,
        name=name or email.split('@')[0],
        token=token,
        token_expiry=token_expiry,
        oauth_provider=oauth_provider,
        groups=["oauth_users"] if oauth_provider else ["api_users"]
    )
    
    user_repo = p8.repository(User)
    user_repo.upsert_records(user)
    
    return user


def is_valid_token_for_user(token: str, email: str) -> bool:
    """Check if token is valid for the given user"""
    user_repo = p8.repository(User)
    users = user_repo.select(email=email)
    
    if not users:
        return False
    
    user = User(**users[0])
    
    # Check token matches
    if user.token != token:
        return False
    
    # Check expiry
    if user.token_expiry and user.token_expiry < datetime.utcnow():
        return False
    
    return True


def get_user_from_email(email: str) -> Optional[User]:
    """Get user by email"""
    user_repo = p8.repository(User)
    users = user_repo.select(email=email)
    
    if users:
        return User(**users[0])
    return None


def get_user_with_role_from_email(email: str) -> Optional[tuple[str, Optional[int]]]:
    """
    Get user ID and role_level by email in a single query
    
    Args:
        email: User's email address
        
    Returns:
        Tuple of (user_id, role_level) if user exists, None otherwise
    """
    try:
        # Use direct SQL query to get both id and role_level efficiently
        query = """SELECT id::TEXT as id, role_level FROM p8."User" WHERE email = %s LIMIT 1"""
        result = p8.repository(User).execute(query, data=(email,))
        
        if result and len(result) > 0:
            user_data = result[0]
            return (user_data['id'], user_data.get('role_level'))
        return None
    except Exception as e:
        logger.warning(f"Failed to get user with role from email {email}: {e}")
        return None


def register_or_update_user(email: str, name: Optional[str] = None,
                           token: Optional[str] = None,
                           oauth_provider: Optional[str] = None,
                           groups: Optional[list] = None) -> User:
    """Register a new user or update existing user"""
    user_id = make_uuid(email)
    user_repo = p8.repository(User)
    
    # Check if user exists
    existing_users = user_repo.select(email=email)
    
    if existing_users:
        # Update existing user
        user = User(**existing_users[0])
        if name:
            user.name = name
        if token:
            user.token = token
        if oauth_provider:
            user.oauth_provider = oauth_provider
        if groups:
            user.groups = groups
    else:
        # Create new user
        user = User(
            id=user_id,
            email=email,
            name=name or email.split('@')[0],
            token=token,
            oauth_provider=oauth_provider,
            groups=groups or ["oauth_users"] if oauth_provider else ["api_users"]
        )
    
    user_repo.upsert_records(user)
    return user


def get_stable_session_key() -> str:
    """Generate a stable session key based on environment or defaults"""
    # Check for explicit session key
    session_key = os.getenv("SESSION_SECRET_KEY")
    if session_key:
        return session_key
    
    # Generate stable key from other environment variables
    stable_seed = os.getenv("P8_API_ENDPOINT", "http://localhost:5008")
    stable_seed += os.getenv("P8_PG_HOST", "localhost")
    stable_seed += os.getenv("P8_PG_DATABASE", "app")
    
    # Create a stable hash
    return hashlib.sha256(stable_seed.encode()).hexdigest()