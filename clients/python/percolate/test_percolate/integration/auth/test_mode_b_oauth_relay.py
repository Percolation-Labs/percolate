"""
Test Mode B: OAuth Provider Relay (Google OAuth without token storage)
"""

import os
import pytest
import httpx
from unittest.mock import patch, Mock
from datetime import datetime, timedelta
import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid
from percolate.api.auth.providers import GoogleOAuthRelayProvider
from percolate.api.auth.models import TokenRequest, TokenResponse, TokenInfo, TokenExpiredError


# Test configuration
TEST_EMAIL = "oauth.test@example.com"
TEST_USER_NAME = "OAuth Test User"
BASE_URL = os.environ.get("P8_API_ENDPOINT", "http://localhost:5008")

# Mock Google OAuth responses
MOCK_GOOGLE_TOKEN_RESPONSE = {
    "access_token": "google-access-token-12345",
    "token_type": "Bearer",
    "expires_in": 3600,
    "refresh_token": "google-refresh-token-67890",
    "id_token": "google-id-token-abcdef",
    "scope": "openid email profile"
}

MOCK_GOOGLE_USERINFO = {
    "email": TEST_EMAIL,
    "name": TEST_USER_NAME,
    "sub": "google-user-id-123",
    "picture": "https://example.com/photo.jpg"
}

MOCK_GOOGLE_TOKEN_VALIDATION = {
    "azp": "test-client-id",
    "aud": "test-client-id",
    "sub": "google-user-id-123",
    "email": TEST_EMAIL,
    "email_verified": "true",
    "exp": str(int((datetime.utcnow() + timedelta(hours=1)).timestamp())),
    "scope": "openid email profile"
}

MOCK_EXPIRED_TOKEN_RESPONSE = {
    "error": "invalid_token",
    "error_description": "Token has been expired or revoked."
}


@pytest.fixture
def google_relay_provider():
    """Create a Google OAuth relay provider"""
    return GoogleOAuthRelayProvider(
        client_id="test-client-id",
        client_secret="test-client-secret",
        redirect_uri="http://localhost:8080/callback"
    )


@pytest.fixture
def cleanup_user():
    """Cleanup test user after tests"""
    yield
    # Remove test user if exists
    user_repo = p8.repository(User)
    user_id = make_uuid(TEST_EMAIL)
    try:
        user = User(id=user_id)
        user_repo.delete_records(user)
    except:
        pass


@pytest.mark.asyncio
async def test_oauth_relay_token_exchange(google_relay_provider, cleanup_user):
    """Test that relay mode doesn't store tokens, only registers user"""
    with patch('httpx.AsyncClient') as mock_client:
        # Mock the token exchange and userinfo requests
        mock_response_token = Mock()
        mock_response_token.status_code = 200
        mock_response_token.json.return_value = MOCK_GOOGLE_TOKEN_RESPONSE
        
        mock_response_userinfo = Mock()
        mock_response_userinfo.status_code = 200
        mock_response_userinfo.json.return_value = MOCK_GOOGLE_USERINFO
        
        mock_client_instance = Mock()
        mock_client_instance.post.return_value = mock_response_token
        mock_client_instance.get.return_value = mock_response_userinfo
        mock_client.return_value.__aenter__.return_value = mock_client_instance
        
        # Exchange code for token
        request = TokenRequest(
            grant_type="authorization_code",
            code="test-auth-code",
            client_id="test-client-id"
        )
        
        response = await google_relay_provider.token(request)
        
        # Verify response contains Google tokens
        assert response.access_token == "google-access-token-12345"
        assert response.refresh_token == "google-refresh-token-67890"
        assert response.expires_in == 3600
        
        # Verify user was created WITHOUT token
        user_repo = p8.repository(User)
        users = user_repo.select(email=TEST_EMAIL)
        
        assert len(users) == 1
        user = User(**users[0])
        assert user.email == TEST_EMAIL
        assert user.name == TEST_USER_NAME
        assert user.token is None  # No token stored!
        assert user.token_expiry is None
        assert user.groups == ["oauth_users"]


@pytest.mark.asyncio
async def test_oauth_relay_token_validation(google_relay_provider, cleanup_user):
    """Test that validation always checks with Google, not local DB"""
    # First create a user
    user_id = make_uuid(TEST_EMAIL)
    user = User(
        id=user_id,
        email=TEST_EMAIL,
        name=TEST_USER_NAME,
        role_level=10,
        groups=["oauth_users", "premium"]
    )
    user_repo = p8.repository(User)
    user_repo.upsert_records(user)
    
    with patch('httpx.AsyncClient') as mock_client:
        # Mock successful token validation
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = MOCK_GOOGLE_TOKEN_VALIDATION
        
        mock_client_instance = Mock()
        mock_client_instance.get.return_value = mock_response
        mock_client.return_value.__aenter__.return_value = mock_client_instance
        
        # Validate token
        token_info = await google_relay_provider.validate("google-access-token-12345")
        
        # Verify it called Google's tokeninfo endpoint
        mock_client_instance.get.assert_called_with(
            "https://oauth2.googleapis.com/tokeninfo?access_token=google-access-token-12345"
        )
        
        # Verify token info includes user metadata from DB
        assert token_info.active == True
        assert token_info.email == TEST_EMAIL
        assert token_info.provider == "google"
        assert token_info.metadata["role_level"] == 10
        assert token_info.metadata["groups"] == ["oauth_users", "premium"]


@pytest.mark.asyncio
async def test_oauth_relay_expired_token(google_relay_provider):
    """Test that expired tokens raise TokenExpiredError"""
    with patch('httpx.AsyncClient') as mock_client:
        # Mock expired token response
        mock_response = Mock()
        mock_response.status_code = 401
        mock_response.json.return_value = MOCK_EXPIRED_TOKEN_RESPONSE
        
        mock_client_instance = Mock()
        mock_client_instance.get.return_value = mock_response
        mock_client.return_value.__aenter__.return_value = mock_client_instance
        
        # Should raise TokenExpiredError
        with pytest.raises(TokenExpiredError):
            await google_relay_provider.validate("expired-token")


@pytest.mark.asyncio
async def test_mode_b_environment_setup():
    """Test that AUTH_PROVIDER=google sets up relay mode"""
    # Set environment variable
    os.environ["AUTH_PROVIDER"] = "google"
    os.environ["GOOGLE_OAUTH_CLIENT_ID"] = "test-client"
    os.environ["GOOGLE_OAUTH_CLIENT_SECRET"] = "test-secret"
    
    try:
        # Import after setting env vars to test initialization
        from percolate.api.auth.server import OAuthServer
        
        server = OAuthServer("http://localhost:5008")
        
        # Verify Google provider is in relay mode
        assert "google" in server.providers
        google_provider = server.providers["google"]
        assert isinstance(google_provider, GoogleOAuthRelayProvider)
        assert hasattr(google_provider, 'relay_mode')
        assert google_provider.relay_mode == True
        
    finally:
        # Clean up env vars
        if "AUTH_PROVIDER" in os.environ:
            del os.environ["AUTH_PROVIDER"]
        if "GOOGLE_OAUTH_CLIENT_ID" in os.environ:
            del os.environ["GOOGLE_OAUTH_CLIENT_ID"]
        if "GOOGLE_OAUTH_CLIENT_SECRET" in os.environ:
            del os.environ["GOOGLE_OAUTH_CLIENT_SECRET"]


@pytest.mark.asyncio
async def test_user_registration_without_token(google_relay_provider, cleanup_user):
    """Test that users are registered without storing tokens"""
    with patch('httpx.AsyncClient') as mock_client:
        # Mock the token exchange and userinfo requests
        mock_response_token = Mock()
        mock_response_token.status_code = 200
        mock_response_token.json.return_value = MOCK_GOOGLE_TOKEN_RESPONSE
        
        mock_response_userinfo = Mock()
        mock_response_userinfo.status_code = 200
        mock_response_userinfo.json.return_value = MOCK_GOOGLE_USERINFO
        
        mock_client_instance = Mock()
        mock_client_instance.post.return_value = mock_response_token
        mock_client_instance.get.return_value = mock_response_userinfo
        mock_client.return_value.__aenter__.return_value = mock_client_instance
        
        # First login - creates user
        request = TokenRequest(
            grant_type="authorization_code",
            code="test-auth-code-1",
            client_id="test-client-id"
        )
        
        await google_relay_provider.token(request)
        
        # Verify user created
        user_repo = p8.repository(User)
        users = user_repo.select(email=TEST_EMAIL)
        assert len(users) == 1
        first_user_id = users[0]['id']
        
        # Second login - should not duplicate user
        request2 = TokenRequest(
            grant_type="authorization_code",
            code="test-auth-code-2",
            client_id="test-client-id"
        )
        
        await google_relay_provider.token(request2)
        
        # Verify still only one user
        users = user_repo.select(email=TEST_EMAIL)
        assert len(users) == 1
        assert users[0]['id'] == first_user_id


if __name__ == "__main__":
    # Run tests
    pytest.main([__file__, "-v"])