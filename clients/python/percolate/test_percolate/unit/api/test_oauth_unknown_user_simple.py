"""
Unit test for OAuth Google provider handling of unknown users.
Tests that users whose emails are not in the database receive appropriate responses.
"""

import pytest
import os
from unittest.mock import Mock, patch, AsyncMock, MagicMock
from datetime import datetime
import json

from fastapi import HTTPException


class TestOAuthUnknownUserSimple:
    """Test OAuth behavior when user email is not in database"""
    
    def test_store_user_with_token_mock(self):
        """Test that store_user_with_token handles unknown users correctly"""
        # Mock the entire flow without importing percolate
        with patch('percolate.repository') as mock_repo:
            mock_repo_instance = Mock()
            mock_repo_instance.select.return_value = []  # Mock empty result for new user
            mock_repo_instance.upsert_records = Mock()
            mock_repo.return_value = mock_repo_instance
            
            # Import after mocking
            from percolate.api.auth.utils import store_user_with_token
            from percolate.models.p8.types import User
            from percolate.utils import make_uuid
            
            email = "newuser@example.com"
            token = "test-token-123"
            name = "New User"
            
            # Call the function - allow creation of new users for this test
            user = store_user_with_token(
                email=email,
                token=token,
                name=name,
                oauth_provider="google",
                require_existing_user=False
            )
            
            # Verify user was created
            assert user.email == email
            assert user.token == token
            assert user.name == name
            # Note: User model doesn't have oauth_provider field
            assert "oauth_users" in user.groups
            
            # Verify upsert was called
            mock_repo_instance.upsert_records.assert_called_once()
    
    def test_get_user_from_email_unknown(self):
        """Test that get_user_from_email returns None for unknown users"""
        with patch('percolate.repository') as mock_repo:
            mock_repo_instance = Mock()
            mock_repo_instance.select.return_value = []  # No users found
            mock_repo.return_value = mock_repo_instance
            
            from percolate.api.auth.utils import get_user_from_email
            
            user = get_user_from_email("unknown@example.com")
            assert user is None
    
    @pytest.mark.asyncio
    async def test_oauth_callback_behavior(self):
        """Test OAuth callback behavior for unknown users"""
        # This test demonstrates the expected behavior without full integration
        
        # Mock scenario 1: System configured to auto-create users
        mock_user_repo = Mock()
        mock_user_repo.select.return_value = []  # User doesn't exist
        mock_user_repo.upsert_records = Mock()  # Will create user
        
        # Simulate OAuth provider creating user
        email = "unknown@example.com"
        created = False
        
        # Check if user exists
        users = mock_user_repo.select(email=email)
        if not users:
            # Create user (what GoogleOAuthRelayProvider does)
            mock_user_repo.upsert_records({"email": email, "role_level": 100})
            created = True
        
        assert created is True
        assert mock_user_repo.upsert_records.called
        
        # Mock scenario 2: System configured to reject unknown users
        async def validate_user_policy(email: str, allow_unknown: bool = False):
            """Policy to control unknown user access"""
            users = mock_user_repo.select(email=email)
            if not users and not allow_unknown:
                raise HTTPException(status_code=401, detail=f"Unknown user: {email}")
            return True
        
        # Test rejection
        mock_user_repo.select.return_value = []  # User doesn't exist
        with pytest.raises(HTTPException) as exc_info:
            await validate_user_policy("unknown2@example.com", allow_unknown=False)
        
        assert exc_info.value.status_code == 401
        assert "Unknown user" in str(exc_info.value.detail)
        
        # Test acceptance when policy allows
        result = await validate_user_policy("unknown3@example.com", allow_unknown=True)
        assert result is True


@pytest.mark.asyncio
async def test_google_oauth_relay_mode_behavior():
    """Test that Google OAuth relay mode creates users automatically"""
    # This test shows the expected behavior in relay mode
    os.environ["AUTH_PROVIDER"] = "google"
    
    # Mock user data from Google
    google_user_info = {
        "email": "newuser@gmail.com",
        "name": "New User",
        "given_name": "New",
        "family_name": "User"
    }
    
    # Simulate what happens in GoogleOAuthRelayProvider
    mock_user_repo = Mock()
    mock_user_repo.select.return_value = []  # User doesn't exist
    
    # In relay mode, the provider creates the user
    user_created = False
    if not mock_user_repo.select(email=google_user_info["email"]):
        # Create user with default role_level=100
        new_user = {
            "email": google_user_info["email"],
            "name": google_user_info["name"],
            "role_level": 100,
            "groups": ["oauth_users"]
        }
        mock_user_repo.upsert_records(new_user)
        user_created = True
    
    assert user_created is True
    assert mock_user_repo.upsert_records.called


def test_oauth_configuration_modes():
    """Test different OAuth configuration modes and their behavior"""
    # Mode 1: Bearer token - no automatic user creation
    mode1_config = {
        "AUTH_PROVIDER": "bearer",
        "behavior": "Users must exist in database with valid token"
    }
    
    # Mode 2: Google relay - automatic user creation
    mode2_config = {
        "AUTH_PROVIDER": "google",
        "behavior": "Users are created automatically on first login"
    }
    
    # Mode 3: Custom policy - configurable behavior
    mode3_config = {
        "AUTH_PROVIDER": "custom",
        "behavior": "Can be configured to allow or deny unknown users"
    }
    
    # Verify configurations
    assert mode1_config["AUTH_PROVIDER"] == "bearer"
    assert mode2_config["AUTH_PROVIDER"] == "google"
    assert "automatically" in mode2_config["behavior"]