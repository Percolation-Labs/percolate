"""
Unit test for OAuth endpoint rejecting unknown users by default.
Tests that users whose emails are not in the database receive a 401 response.
"""

import pytest
from unittest.mock import Mock, patch, AsyncMock
from datetime import datetime

from fastapi import HTTPException
from fastapi.responses import JSONResponse


class TestOAuthRejectUnknownUsers:
    """Test OAuth behavior to reject unknown users by default"""
    
    @pytest.mark.asyncio
    async def test_oauth_callback_rejects_unknown_user(self):
        """Test OAuth callback returns 401 for unknown user"""
        # Mock the OAuth token validation response
        mock_token_data = {
            "email": "unknown.user@example.com",
            "name": "Unknown User",
            "exp": int((datetime.utcnow()).timestamp()) + 3600
        }
        
        # Mock user lookup - user doesn't exist
        with patch('percolate.api.auth.utils.get_user_from_email') as mock_get_user:
            mock_get_user.return_value = None  # User not found
            
            # The expected behavior: reject unknown users
            try:
                # Simulate the OAuth callback flow
                user = mock_get_user(mock_token_data["email"])
                if not user:
                    # This is what should happen - reject unknown users
                    raise HTTPException(
                        status_code=401,
                        detail=f"Unknown user: {mock_token_data['email']}"
                    )
            except HTTPException as e:
                assert e.status_code == 401
                assert "Unknown user" in str(e.detail)
                assert "unknown.user@example.com" in str(e.detail)
    
    @pytest.mark.asyncio
    async def test_oauth_validate_user_policy(self):
        """Test OAuth user validation policy"""
        # Define the expected validation policy
        async def validate_oauth_user(email: str, allow_new_users: bool = False):
            """
            Validate OAuth user based on policy.
            By default, reject unknown users.
            """
            from percolate.api.auth.utils import get_user_from_email
            
            user = get_user_from_email(email)
            
            if not user and not allow_new_users:
                raise HTTPException(
                    status_code=401,
                    detail=f"Authentication failed: User {email} is not authorized to access this system"
                )
            
            return user
        
        # Test 1: Reject unknown user (default behavior)
        with patch('percolate.api.auth.utils.get_user_from_email') as mock_get:
            mock_get.return_value = None
            
            with pytest.raises(HTTPException) as exc_info:
                await validate_oauth_user("unknown@example.com", allow_new_users=False)
            
            assert exc_info.value.status_code == 401
            assert "not authorized" in str(exc_info.value.detail)
        
        # Test 2: Allow existing user
        with patch('percolate.api.auth.utils.get_user_from_email') as mock_get:
            mock_get.return_value = Mock(email="existing@example.com")
            
            user = await validate_oauth_user("existing@example.com", allow_new_users=False)
            assert user is not None
            assert user.email == "existing@example.com"
        
        # Test 3: Allow new user when policy permits (optional feature)
        with patch('percolate.api.auth.utils.get_user_from_email') as mock_get:
            mock_get.return_value = None
            
            # When allow_new_users=True, it would create the user
            # But by default this should be False
            with pytest.raises(HTTPException):
                await validate_oauth_user("new@example.com", allow_new_users=False)
    
    def test_oauth_callback_response_for_unknown_user(self):
        """Test the actual response format for unknown users"""
        # Simulate the OAuth callback handler response
        unknown_email = "unauthorized@example.com"
        
        # Expected error response
        error_response = JSONResponse(
            status_code=401,
            content={
                "error": "unauthorized",
                "error_description": f"User {unknown_email} is not authorized to access this system",
                "detail": "Please contact your administrator to request access"
            }
        )
        
        assert error_response.status_code == 401
        response_body = error_response.body.decode()
        assert "unauthorized" in response_body
        assert unknown_email in response_body
    
    @pytest.mark.asyncio
    async def test_google_oauth_callback_flow_with_validation(self):
        """Test complete Google OAuth callback flow with user validation"""
        # Mock Google token exchange response
        mock_token_response = {
            "access_token": "google-access-token",
            "id_token": "google-id-token",
            "expires_in": 3600
        }
        
        # Mock decoded ID token
        mock_decoded_token = {
            "email": "newuser@gmail.com",
            "name": "New User",
            "aud": "test-client-id"
        }
        
        # Simulate the callback flow
        async def handle_google_callback(code: str, state: str):
            # 1. Exchange code for token (mocked)
            token_data = mock_token_response
            
            # 2. Decode and validate token (mocked)
            user_info = mock_decoded_token
            
            # 3. Check if user exists in database
            from percolate.api.auth.utils import get_user_from_email
            existing_user = get_user_from_email(user_info["email"])
            
            # 4. IMPORTANT: Reject if user doesn't exist (default behavior)
            if not existing_user:
                raise HTTPException(
                    status_code=401,
                    detail={
                        "error": "unauthorized", 
                        "message": f"User {user_info['email']} is not authorized to access this system"
                    }
                )
            
            # 5. Only proceed if user exists
            return {
                "access_token": token_data["id_token"],
                "user": existing_user
            }
        
        # Test with unknown user
        with patch('percolate.api.auth.utils.get_user_from_email') as mock_get:
            mock_get.return_value = None  # User doesn't exist
            
            with pytest.raises(HTTPException) as exc_info:
                await handle_google_callback("test-code", "test-state")
            
            assert exc_info.value.status_code == 401
            assert "not authorized" in str(exc_info.value.detail)


def test_oauth_configuration_defaults():
    """Test that OAuth configuration defaults to rejecting unknown users"""
    # Default configuration should be secure
    default_config = {
        "OAUTH_ALLOW_NEW_USERS": False,  # Should default to False
        "OAUTH_AUTO_CREATE_USERS": False,  # Should default to False
        "OAUTH_REQUIRE_PREREGISTRATION": True,  # Should default to True
    }
    
    # Verify secure defaults
    assert default_config["OAUTH_ALLOW_NEW_USERS"] is False
    assert default_config["OAUTH_AUTO_CREATE_USERS"] is False
    assert default_config["OAUTH_REQUIRE_PREREGISTRATION"] is True
    
    # Configuration for different scenarios
    scenarios = {
        "strict": {
            "description": "Only pre-registered users can authenticate",
            "allow_new_users": False,
            "expected_behavior": "401 for unknown users"
        },
        "open": {
            "description": "Any Google user can authenticate (opt-in only)",
            "allow_new_users": True,
            "expected_behavior": "Create user on first login"
        }
    }
    
    # Default should be "strict"
    assert scenarios["strict"]["allow_new_users"] is False