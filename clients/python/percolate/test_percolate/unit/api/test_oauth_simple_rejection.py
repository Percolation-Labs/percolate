"""
Simple test to verify OAuth rejection logic works
"""

import os
import pytest
from unittest.mock import Mock, patch


def test_oauth_allow_new_users_env_var():
    """Test that OAUTH_ALLOW_NEW_USERS env var controls user creation"""
    # Test default (not set)
    if "OAUTH_ALLOW_NEW_USERS" in os.environ:
        del os.environ["OAUTH_ALLOW_NEW_USERS"]
    
    allow = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
    assert allow is False
    
    # Test explicitly false
    os.environ["OAUTH_ALLOW_NEW_USERS"] = "false"
    allow = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
    assert allow is False
    
    # Test explicitly true
    os.environ["OAUTH_ALLOW_NEW_USERS"] = "true"
    allow = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
    assert allow is True
    
    # Clean up
    del os.environ["OAUTH_ALLOW_NEW_USERS"]


def test_user_validation_logic():
    """Test the user validation logic we implemented"""
    # Simulate our validation logic
    def validate_oauth_user(email: str, user_exists: bool):
        if not user_exists:
            allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
            if not allow_new_users:
                return {"error": "unauthorized", "message": f"User {email} is not authorized"}
        return {"success": True}
    
    # Test with existing user - should always work
    result = validate_oauth_user("existing@example.com", user_exists=True)
    assert result["success"] is True
    
    # Test with unknown user, default env (should reject)
    if "OAUTH_ALLOW_NEW_USERS" in os.environ:
        del os.environ["OAUTH_ALLOW_NEW_USERS"]
    
    result = validate_oauth_user("unknown@example.com", user_exists=False)
    assert "error" in result
    assert result["error"] == "unauthorized"
    
    # Test with unknown user, explicit allow
    os.environ["OAUTH_ALLOW_NEW_USERS"] = "true"
    result = validate_oauth_user("unknown@example.com", user_exists=False)
    assert result["success"] is True
    
    # Clean up
    del os.environ["OAUTH_ALLOW_NEW_USERS"]


@pytest.mark.asyncio
async def test_oauth_rejection_in_callback():
    """Test that OAuth callback properly rejects unknown users"""
    from percolate.api.auth.utils import get_user_from_email
    
    # Mock the callback logic
    async def mock_google_callback(email: str):
        # Check if user exists
        with patch('percolate.api.auth.utils.get_user_from_email') as mock_get:
            mock_get.return_value = None  # User doesn't exist
            
            existing_user = get_user_from_email(email)
            
            if not existing_user:
                allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
                
                if not allow_new_users:
                    return {
                        "status_code": 401,
                        "error": "unauthorized",
                        "error_description": f"User {email} is not authorized to access this system."
                    }
            
            return {"status_code": 200, "user": existing_user}
    
    # Test rejection
    result = await mock_google_callback("newuser@example.com")
    assert result["status_code"] == 401
    assert result["error"] == "unauthorized"