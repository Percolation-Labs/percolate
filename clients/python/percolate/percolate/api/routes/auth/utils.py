"""Auth utility functions for routes - imports from auth.utils to avoid circular imports"""

# Re-export all functions from auth.utils
from percolate.api.auth.utils import (
    decode_jwt_token,
    extract_token_expiry,
    extract_user_info_from_token,
    store_user_with_token,
    is_valid_token_for_user,
    get_user_from_email,
    register_or_update_user,
    get_stable_session_key
)

# Keep any route-specific utilities here
import hashlib
import uuid
from typing import Optional
from datetime import datetime
import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import logger


def validate_bearer_token(token: str, email: Optional[str] = None) -> Optional[User]:
    """
    Validate a bearer token and optionally check it matches the email.
    Used by routes for bearer token authentication.
    """
    if not token:
        return None
    
    # If email is provided, validate token for that user
    if email:
        if is_valid_token_for_user(token, email):
            return get_user_from_email(email)
        else:
            return None
    
    # Otherwise, find user by token
    user_repo = p8.repository(User)
    users = user_repo.select(token=token)
    
    if not users:
        return None
    
    user = User(**users[0])
    
    # Check token expiry
    if user.token_expiry and user.token_expiry < datetime.utcnow():
        return None
    
    return user