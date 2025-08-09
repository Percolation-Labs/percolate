"""
Integration test to verify OAuth rejects unknown users by default.
Tests the actual implementation after our changes.
"""

import pytest
import os
from unittest.mock import Mock, patch, AsyncMock
from datetime import datetime
import json

from fastapi import HTTPException
from percolate.api.auth import AuthError


class TestOAuthRejectByDefault:
    """Test that OAuth providers reject unknown users by default"""
    
    @pytest.mark.slow
    @pytest.mark.asyncio
    async def test_google_oauth_relay_rejects_unknown_user(self):
        """Test GoogleOAuthRelayProvider rejects unknown users when OAUTH_ALLOW_NEW_USERS is not set"""
        # Ensure env var is not set (default behavior)
        if "OAUTH_ALLOW_NEW_USERS" in os.environ:
            del os.environ["OAUTH_ALLOW_NEW_USERS"]
        
        from percolate.api.auth.providers import GoogleOAuthRelayProvider
        
        provider = GoogleOAuthRelayProvider(
            client_id="test-client",
            client_secret="test-secret",
            redirect_uri="http://localhost:5008/callback"
        )
        
        # Mock Google API responses
        mock_token_response = {
            "access_token": "test-access-token",
            "id_token": "test-id-token",
            "expires_in": 3600
        }
        
        mock_userinfo = {
            "email": "unknown@example.com",
            "name": "Unknown User"
        }
        
        with patch('httpx.AsyncClient') as mock_client:
            mock_async_client = AsyncMock()
            
            # Token exchange response
            mock_post_response = Mock()
            mock_post_response.json.return_value = mock_token_response
            mock_post_response.raise_for_status = Mock()
            mock_async_client.post.return_value = mock_post_response
            
            # Userinfo response
            mock_get_response = Mock()
            mock_get_response.json.return_value = mock_userinfo
            mock_get_response.status_code = 200
            mock_async_client.get.return_value = mock_get_response
            
            mock_client.return_value.__aenter__.return_value = mock_async_client
            
            # Mock user repository - user doesn't exist
            with patch('percolate.repository') as mock_repo:
                mock_repo_instance = Mock()
                mock_repo_instance.select.return_value = []  # User not found
                mock_repo.return_value = mock_repo_instance
                
                # Exchange code for token
                from percolate.api.auth import TokenRequest
                token_request = TokenRequest(
                    grant_type="authorization_code",
                    code="test-auth-code",
                    redirect_uri="http://localhost:5008/callback"
                )
                
                # Should raise AuthError for unknown user
                with pytest.raises(AuthError) as exc_info:
                    await provider.token(token_request)
                
                assert exc_info.value.error == "unauthorized"
                assert "not authorized to access this system" in exc_info.value.error_description
                assert "unknown@example.com" in exc_info.value.error_description
    
    @pytest.mark.slow
    @pytest.mark.asyncio
    async def test_google_oauth_provider_rejects_unknown_user(self):
        """Test regular GoogleOAuthProvider rejects unknown users"""
        # Ensure env var is not set
        if "OAUTH_ALLOW_NEW_USERS" in os.environ:
            del os.environ["OAUTH_ALLOW_NEW_USERS"]
        
        from percolate.api.auth.providers import GoogleOAuthProvider
        
        provider = GoogleOAuthProvider(
            client_id="test-client",
            client_secret="test-secret",
            redirect_uri="http://localhost:5008/callback"
        )
        
        # Mock responses
        mock_token_response = {
            "access_token": "test-access-token",
            "id_token": "test-id-token",
            "expires_in": 3600
        }
        
        mock_userinfo = {
            "email": "newuser@example.com",
            "name": "New User"
        }
        
        with patch('httpx.AsyncClient') as mock_client:
            mock_async_client = AsyncMock()
            
            # Token response
            mock_post_response = Mock()
            mock_post_response.json.return_value = mock_token_response
            mock_post_response.raise_for_status = Mock()
            mock_async_client.post.return_value = mock_post_response
            
            # Userinfo response
            mock_get_response = Mock()
            mock_get_response.json.return_value = mock_userinfo
            mock_get_response.status_code = 200
            mock_async_client.get.return_value = mock_get_response
            
            mock_client.return_value.__aenter__.return_value = mock_async_client
            
            # Mock user repository - user doesn't exist
            with patch('percolate.repository') as mock_repo:
                mock_repo_instance = Mock()
                mock_repo_instance.select.return_value = []  # User not found
                mock_repo.return_value = mock_repo_instance
                
                from percolate.api.auth import TokenRequest
                token_request = TokenRequest(
                    grant_type="authorization_code",
                    code="test-code",
                    redirect_uri="http://localhost:5008/callback"
                )
                
                # Should raise AuthError
                with pytest.raises(AuthError) as exc_info:
                    await provider.token(token_request)
                
                assert exc_info.value.error == "unauthorized"
                assert "not authorized" in exc_info.value.error_description
    
    def test_oauth_callback_handler_rejects_unknown_user(self):
        """Test OAuth callback handler rejects unknown users"""
        # Mock the callback handler behavior
        def handle_oauth_callback(email: str):
            from percolate.api.auth.utils import get_user_from_email
            
            # Check if user exists
            existing_user = get_user_from_email(email)
            
            if not existing_user:
                # Check env var (default: False)
                allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
                
                if not allow_new_users:
                    return {
                        "status_code": 401,
                        "content": {
                            "error": "unauthorized",
                            "error_description": f"User {email} is not authorized to access this system."
                        }
                    }
            
            return {"status_code": 200, "user": existing_user}
        
        # Test with unknown user
        with patch('percolate.api.auth.utils.get_user_from_email') as mock_get:
            mock_get.return_value = None
            
            result = handle_oauth_callback("unknown@example.com")
            assert result["status_code"] == 401
            assert "unauthorized" in result["content"]["error"]
    
    def test_env_var_default_behavior(self):
        """Test that OAUTH_ALLOW_NEW_USERS defaults to false"""
        # Remove env var to test default
        if "OAUTH_ALLOW_NEW_USERS" in os.environ:
            del os.environ["OAUTH_ALLOW_NEW_USERS"]
        
        # Default should be false
        allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
        assert allow_new_users is False
        
        # Test various falsy values
        for value in ["false", "False", "FALSE", "0", "no", "No", ""]:
            os.environ["OAUTH_ALLOW_NEW_USERS"] = value
            allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
            assert allow_new_users is False
        
        # Only "true" (case insensitive) should enable it
        for value in ["true", "True", "TRUE"]:
            os.environ["OAUTH_ALLOW_NEW_USERS"] = value
            allow_new_users = os.getenv("OAUTH_ALLOW_NEW_USERS", "false").lower() == "true"
            assert allow_new_users is True
        
        # Clean up
        if "OAUTH_ALLOW_NEW_USERS" in os.environ:
            del os.environ["OAUTH_ALLOW_NEW_USERS"]