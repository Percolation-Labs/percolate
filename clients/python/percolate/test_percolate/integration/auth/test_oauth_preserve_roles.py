#!/usr/bin/env python3
"""
Test OAuth login flow to ensure it preserves existing user roles and data
"""

import pytest
import asyncio
from unittest.mock import Mock, patch, AsyncMock
from datetime import datetime

import sys
from pathlib import Path
project_root = Path(__file__).parent.parent.parent.parent
sys.path.insert(0, str(project_root))

import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid
from percolate.api.auth.providers import GoogleOAuthRelayProvider
from percolate.api.auth.models import TokenRequest, GrantType, TokenResponse


class TestOAuthPreserveRoles:
    """Test that OAuth login preserves existing user roles and data"""
    
    def test_existing_user_role_preservation(self):
        """Test that existing users preserve their role_level during OAuth login"""
        
        email = "existing_user@example.com"
        user_id = make_uuid(email)
        original_role_level = 20  # High privilege user
        original_name = "Original Name"
        
        # Create an existing user with high privilege level
        with patch('percolate.repository') as mock_repo:
            mock_repo_instance = Mock()
            mock_repo.return_value = mock_repo_instance
            
            # Mock existing user in database
            existing_user_data = {
                'id': user_id,
                'name': original_name,
                'email': email,
                'role_level': original_role_level,
                'groups': ['admin_users'],
                'metadata': {'created_at': '2024-01-01'}
            }
            mock_repo_instance.select.return_value = [existing_user_data]
            mock_repo_instance.update_records = Mock()
            
            # Import OAuth provider after mocking
            from percolate.api.auth.providers import GoogleOAuthRelayProvider
            
            # Create provider instance
            provider = GoogleOAuthRelayProvider(
                client_id="test_client_id",
                client_secret="test_client_secret", 
                redirect_uri="http://localhost/callback"
            )
            
            # Mock the OAuth token data from Google
            mock_token_data = {
                "access_token": "fake_access_token",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "fake_refresh_token",
                "id_token": "fake_id_token"
            }
            
            # Mock the Google user info
            mock_user_info = {
                "email": email,
                "name": "Updated Name From Google",  # Name changed in Google
                "given_name": "Updated",
                "family_name": "Name"
            }
            
            with patch.object(provider, '_exchange_code_for_token', return_value=mock_token_data), \
                 patch.object(provider, '_get_user_info', return_value=mock_user_info):
                
                # Simulate OAuth login
                token_request = TokenRequest(
                    grant_type=GrantType.AUTHORIZATION_CODE,
                    code="fake_auth_code"
                )
                
                # This should trigger the OAuth flow
                result = asyncio.run(provider.authenticate(token_request))
                
                # Verify result is a TokenResponse
                assert isinstance(result, TokenResponse)
                assert result.access_token == "fake_access_token"
                
                # Verify that the user repository was called correctly
                mock_repo_instance.select.assert_called_once_with(email=email)
                
                # Verify that update_records was called (for existing user)
                mock_repo_instance.update_records.assert_called_once()
                
                # Get the user object that was passed to update_records
                updated_user_call = mock_repo_instance.update_records.call_args[0][0]
                
                # Verify the user's role_level was PRESERVED
                assert updated_user_call.role_level == original_role_level, \
                    f"Role level should be preserved! Expected {original_role_level}, got {updated_user_call.role_level}"
                
                # Verify name was updated (this is allowed)
                assert updated_user_call.name == "Updated Name From Google", \
                    f"Name should be updated from Google. Expected 'Updated Name From Google', got {updated_user_call.name}"
                
                # Verify other critical fields are preserved
                assert updated_user_call.email == email
                assert updated_user_call.id == user_id
                
                print("✅ Test passed: Existing user role_level preserved during OAuth login")
                
    def test_new_user_gets_default_role(self):
        """Test that new users get default role_level=100"""
        
        email = "new_user@example.com" 
        user_id = make_uuid(email)
        
        with patch('percolate.repository') as mock_repo:
            mock_repo_instance = Mock()
            mock_repo.return_value = mock_repo_instance
            
            # Mock no existing user (empty result)
            mock_repo_instance.select.return_value = []
            mock_repo_instance.upsert_records = Mock()
            
            # Import OAuth provider after mocking
            from percolate.api.auth.providers import GoogleOAuthRelayProvider
            
            # Create provider instance  
            provider = GoogleOAuthRelayProvider(
                client_id="test_client_id",
                client_secret="test_client_secret",
                redirect_uri="http://localhost/callback"
            )
            
            # Mock token and user data
            mock_token_data = {
                "access_token": "fake_access_token", 
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "fake_refresh_token",
                "id_token": "fake_id_token"
            }
            
            mock_user_info = {
                "email": email,
                "name": "New User Name",
                "given_name": "New",
                "family_name": "User"
            }
            
            with patch.object(provider, '_exchange_code_for_token', return_value=mock_token_data), \
                 patch.object(provider, '_get_user_info', return_value=mock_user_info), \
                 patch('percolate.api.auth.providers.make_uuid', return_value=user_id):
                
                # Set allow_new_users=True for this test
                with patch.dict('os.environ', {'P8_ALLOW_NEW_USERS': 'true'}):
                    
                    token_request = TokenRequest(
                        grant_type=GrantType.AUTHORIZATION_CODE,
                        code="fake_auth_code"
                    )
                    
                    result = asyncio.run(provider.authenticate(token_request))
                    
                    # Verify result
                    assert isinstance(result, TokenResponse)
                    
                    # Verify upsert_records was called for new user
                    mock_repo_instance.upsert_records.assert_called_once()
                    
                    # Get the user object that was created
                    created_user_call = mock_repo_instance.upsert_records.call_args[0][0]
                    
                    # Verify new user gets default role_level=100
                    assert created_user_call.role_level == 100, \
                        f"New user should get role_level=100! Got {created_user_call.role_level}"
                    
                    assert created_user_call.email == email
                    assert created_user_call.name == "New User Name"
                    assert "oauth_users" in created_user_call.groups
                    
                    print("✅ Test passed: New user gets default role_level=100")

    def test_existing_user_data_preservation(self):
        """Test that existing user metadata and other fields are preserved"""
        
        email = "power_user@example.com"
        user_id = make_uuid(email)
        
        with patch('percolate.repository') as mock_repo:
            mock_repo_instance = Mock()
            mock_repo.return_value = mock_repo_instance
            
            # Mock existing user with rich data
            existing_user_data = {
                'id': user_id,
                'name': "Power User",
                'email': email,
                'role_level': 10,  # Very high privilege
                'groups': ['admin_users', 'power_users'],
                'metadata': {
                    'created_at': '2024-01-01',
                    'last_login': '2024-08-01',
                    'preferences': {'theme': 'dark'}
                },
                'description': 'System administrator',
                'interesting_entity_keys': {'project_alpha': True},
                'roles': ['admin', 'developer']
            }
            mock_repo_instance.select.return_value = [existing_user_data]
            mock_repo_instance.update_records = Mock()
            
            from percolate.api.auth.providers import GoogleOAuthRelayProvider
            
            provider = GoogleOAuthRelayProvider(
                client_id="test_client_id", 
                client_secret="test_client_secret",
                redirect_uri="http://localhost/callback"
            )
            
            mock_token_data = {
                "access_token": "fake_access_token",
                "token_type": "Bearer", 
                "expires_in": 3600
            }
            
            mock_user_info = {
                "email": email,
                "name": "Power User Updated",  # Name updated
                "given_name": "Power",
                "family_name": "User Updated"
            }
            
            with patch.object(provider, '_exchange_code_for_token', return_value=mock_token_data), \
                 patch.object(provider, '_get_user_info', return_value=mock_user_info):
                
                token_request = TokenRequest(
                    grant_type=GrantType.AUTHORIZATION_CODE,
                    code="fake_auth_code"
                )
                
                result = asyncio.run(provider.authenticate(token_request))
                
                # Verify update was called
                mock_repo_instance.update_records.assert_called_once()
                updated_user = mock_repo_instance.update_records.call_args[0][0]
                
                # Critical data preservation checks
                assert updated_user.role_level == 10, "Role level must be preserved"
                assert updated_user.email == email, "Email must be preserved"  
                assert updated_user.id == user_id, "User ID must be preserved"
                
                # Name update is allowed
                assert updated_user.name == "Power User Updated", "Name should be updated from Google"
                
                print("✅ Test passed: All critical user data preserved during OAuth")


if __name__ == "__main__":
    test = TestOAuthPreserveRoles()
    test.test_existing_user_role_preservation()
    test.test_new_user_gets_default_role()
    test.test_existing_user_data_preservation()
    print("\n🎉 All OAuth role preservation tests passed!")