"""
Integration tests for all three authentication modes
"""

import os
import pytest
import httpx
import jwt
from datetime import datetime, timedelta
from unittest.mock import patch, Mock, AsyncMock
import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid
from percolate.api.auth.server import OAuthServer
from percolate.api.auth.models import TokenRequest, AuthRequest


# Test configuration
BASE_URL = os.environ.get("P8_API_ENDPOINT", "http://localhost:5008")


class TestMode1LegacyBearer:
    """Test Mode 1: Legacy Bearer Token Authentication"""
    
    @pytest.fixture
    def test_user(self):
        """Create a test user for identification (global API key used for auth)"""
        email = "mode1.test@example.com"
        # Use 'postgres' as the test API key for localhost testing
        api_key = "postgres"
        
        user_id = make_uuid(email)
        user = User(
            id=user_id,
            name="Mode 1 Test User",
            email=email,
            # No token stored - user identification only
            token=None,
            token_expiry=None,
            role_level=10,
            groups=["test_group"]
        )
        
        user_repo = p8.repository(User)
        user_repo.upsert_records(user)
        
        yield user, api_key
        
        # Cleanup
        try:
            user_repo.delete_records(user)
        except:
            pass
    
    @pytest.mark.asyncio
    async def test_mode1_api_request(self, test_user):
        """Test Mode 1: API request with global API key and user email"""
        user, api_key = test_user
        
        async with httpx.AsyncClient() as client:
            # Test successful authentication with global API key + user email
            response = await client.get(
                f"{BASE_URL}/auth/ping",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "X-User-Email": user.email
                }
            )
            
            assert response.status_code == 200
            data = response.json()
            assert "user_id" in data or "message" in data
    
    @pytest.mark.asyncio
    async def test_mode1_missing_email(self, test_user):
        """Test Mode 1: Works with global API key even without email header"""
        user, api_key = test_user
        
        async with httpx.AsyncClient() as client:
            # Global API key should work without email (no user context)
            response = await client.get(
                f"{BASE_URL}/auth/ping",
                headers={
                    "Authorization": f"Bearer {api_key}"
                }
            )
            
            # Should succeed but with no user context
            assert response.status_code == 200
            data = response.json()
            assert data.get("auth_type") == "bearer"
    
    @pytest.mark.asyncio
    async def test_mode1_oauth_endpoints_exist(self):
        """Test Mode 1: OAuth endpoints exist but aren't typically used for bearer auth"""
        async with httpx.AsyncClient() as client:
            # /auth/authorize endpoint exists (may require auth)
            response = await client.get(f"{BASE_URL}/auth/authorize")
            # Should either return form/redirect or require auth
            assert response.status_code in [200, 302, 401]
            
            # /auth/token endpoint exists
            response = await client.post(
                f"{BASE_URL}/auth/token",
                data={"grant_type": "authorization_code", "code": "dummy"}
            )
            # Should fail as no valid code exists
            assert response.status_code in [400, 401]


class TestMode2PercolateOAuth:
    """Test Mode 2: Percolate as OAuth Provider with JWT"""
    
    @pytest.fixture
    def jwt_environment(self):
        """Set up JWT environment"""
        os.environ["AUTH_MODE"] = "percolate"
        os.environ["JWT_SECRET"] = "test-jwt-secret"
        
        yield
        
        # Cleanup
        if "AUTH_MODE" in os.environ:
            del os.environ["AUTH_MODE"]
        if "JWT_SECRET" in os.environ:
            del os.environ["JWT_SECRET"]
    
    @pytest.fixture
    def test_user(self):
        """Create a test user for JWT auth"""
        email = "mode2.test@example.com"
        token = "sk-mode2-bearer-token"
        
        user_id = make_uuid(email)
        user = User(
            id=user_id,
            name="Mode 2 Test User",
            email=email,
            token=token,
            role_level=10,
            groups=["jwt_users"]
        )
        
        user_repo = p8.repository(User)
        user_repo.upsert_records(user)
        
        yield user, token
        
        # Cleanup
        try:
            user_repo.delete_records(user)
        except:
            pass
    
    @pytest.mark.asyncio
    async def test_mode2_full_oauth_flow(self, jwt_environment, test_user):
        """Test Mode 2: Complete OAuth flow with JWT"""
        user, bearer_token = test_user
        
        # Import after env setup
        from percolate.api.auth.server import OAuthServer
        from percolate.api.auth.jwt_provider import PercolateJWTProvider
        
        server = OAuthServer(BASE_URL)
        
        # Verify JWT provider is active
        assert "percolate" in server.providers
        assert isinstance(server.providers["percolate"], PercolateJWTProvider)
        
        # Step 1: Authorization request
        auth_request = AuthRequest(
            client_id="test-client",
            redirect_uri="http://localhost:8080/callback",
            bearer_token=bearer_token,
            user_email=user.email,
            provider="percolate"
        )
        
        auth_response = await server.authorize(auth_request)
        assert auth_response.code is not None
        
        # Step 2: Token exchange
        token_request = TokenRequest(
            grant_type="authorization_code",
            code=auth_response.code,
            client_id="test-client"
        )
        
        token_response = await server.token(token_request)
        assert token_response.access_token is not None
        assert token_response.refresh_token is not None
        assert token_response.expires_in == 3600
        
        # Step 3: Validate JWT
        token_info = await server.validate_token(token_response.access_token)
        assert token_info.active == True
        assert token_info.email == user.email
        assert token_info.metadata["role_level"] == 10
        
        # Step 4: Decode JWT to verify structure
        payload = jwt.decode(
            token_response.access_token,
            "test-jwt-secret",
            algorithms=["HS256"],
            audience="percolate-api",
            options={"verify_exp": False}
        )
        assert payload["email"] == user.email
        assert payload["token_type"] == "access"
        assert "exp" in payload
        assert "iat" in payload
    
    @pytest.mark.asyncio
    async def test_mode2_token_refresh(self, jwt_environment, test_user):
        """Test Mode 2: JWT refresh token flow"""
        user, bearer_token = test_user
        
        from percolate.api.auth.server import OAuthServer
        server = OAuthServer(BASE_URL)
        
        # Get initial tokens
        auth_request = AuthRequest(
            client_id="test-client",
            bearer_token=bearer_token,
            user_email=user.email,
            provider="percolate"
        )
        
        auth_response = await server.authorize(auth_request)
        
        token_request = TokenRequest(
            grant_type="authorization_code",
            code=auth_response.code,
            client_id="test-client"
        )
        
        initial_tokens = await server.token(token_request)
        
        # Refresh token
        refresh_request = TokenRequest(
            grant_type="refresh_token",
            refresh_token=initial_tokens.refresh_token
        )
        
        refreshed_tokens = await server.token(refresh_request)
        assert refreshed_tokens.access_token != initial_tokens.access_token
        assert refreshed_tokens.refresh_token == initial_tokens.refresh_token
        assert refreshed_tokens.expires_in == 3600
    
    @pytest.mark.asyncio
    async def test_mode2_jwt_expiry(self, jwt_environment):
        """Test Mode 2: JWT expiration handling"""
        from percolate.api.auth.jwt_provider import PercolateJWTProvider
        from percolate.api.auth.models import TokenExpiredError
        
        provider = PercolateJWTProvider(
            jwt_secret="test-secret",
            access_token_expiry=1  # 1 second expiry for testing
        )
        
        # Create expired JWT
        expired_jwt = jwt.encode(
            {
                "sub": "test-user",
                "email": "test@example.com",
                "exp": int((datetime.utcnow() - timedelta(hours=1)).timestamp()),
                "iat": int((datetime.utcnow() - timedelta(hours=2)).timestamp()),
                "iss": "https://api.percolate.ai",
                "aud": "percolate-api",
                "token_type": "access"
            },
            "test-secret",
            algorithm="HS256"
        )
        
        # Should raise TokenExpiredError
        with pytest.raises(TokenExpiredError):
            await provider.validate(expired_jwt)


class TestMode3ExternalOAuthRelay:
    """Test Mode 3: External OAuth Provider Relay"""
    
    @pytest.fixture
    def google_relay_environment(self):
        """Set up Google OAuth relay environment"""
        os.environ["AUTH_PROVIDER"] = "google"
        os.environ["GOOGLE_OAUTH_CLIENT_ID"] = "test-client-id"
        os.environ["GOOGLE_OAUTH_CLIENT_SECRET"] = "test-client-secret"
        
        yield
        
        # Cleanup
        for key in ["AUTH_PROVIDER", "GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"]:
            if key in os.environ:
                del os.environ[key]
    
    @pytest.mark.asyncio
    async def test_mode3_token_not_stored(self, google_relay_environment):
        """Test Mode 3: Tokens are not stored in database"""
        from percolate.api.auth.server import OAuthServer
        from percolate.api.auth.providers import GoogleOAuthRelayProvider
        
        server = OAuthServer(BASE_URL)
        
        # Verify relay provider is active
        assert "google" in server.providers
        assert isinstance(server.providers["google"], GoogleOAuthRelayProvider)
        assert hasattr(server.providers["google"], 'relay_mode')
        
        # Mock Google API responses
        with patch('httpx.AsyncClient') as mock_client:
            # Mock token exchange
            mock_token_response = Mock()
            mock_token_response.status_code = 200
            mock_token_response.json.return_value = {
                "access_token": "google-access-token",
                "refresh_token": "google-refresh-token",
                "expires_in": 3600,
                "token_type": "Bearer"
            }
            
            # Mock userinfo
            mock_userinfo_response = Mock()
            mock_userinfo_response.status_code = 200
            mock_userinfo_response.json.return_value = {
                "email": "mode3.test@example.com",
                "name": "Mode 3 Test User"
            }
            
            mock_client_instance = AsyncMock()
            mock_client_instance.post.return_value = mock_token_response
            mock_client_instance.get.return_value = mock_userinfo_response
            mock_client.return_value.__aenter__.return_value = mock_client_instance
            
            # Exchange code for token
            token_request = TokenRequest(
                grant_type="authorization_code",
                code="test-google-code",
                client_id="test-client-id"
            )
            
            provider = server.providers["google"]
            token_response = await provider.token(token_request)
            
            # Verify user was created without token
            user_repo = p8.repository(User)
            users = user_repo.select(email="mode3.test@example.com")
            
            if users:
                user = User(**users[0])
                assert user.token is None  # No token stored!
                assert user.token_expiry is None
                
                # Cleanup
                user_repo.delete_records(user)
    
    @pytest.mark.asyncio
    async def test_mode3_token_validation_relay(self, google_relay_environment):
        """Test Mode 3: Token validation always goes to provider"""
        from percolate.api.auth.server import OAuthServer
        
        server = OAuthServer(BASE_URL)
        provider = server.providers["google"]
        
        with patch('httpx.AsyncClient') as mock_client:
            # Mock successful validation
            mock_response = Mock()
            mock_response.status_code = 200
            mock_response.json.return_value = {
                "email": "mode3.test@example.com",
                "azp": "test-client-id",
                "exp": str(int((datetime.utcnow() + timedelta(hours=1)).timestamp()))
            }
            
            mock_client_instance = AsyncMock()
            mock_client_instance.get.return_value = mock_response
            mock_client.return_value.__aenter__.return_value = mock_client_instance
            
            # Validate token
            token_info = await provider.validate("google-access-token")
            
            # Verify it called Google's tokeninfo endpoint
            mock_client_instance.get.assert_called_with(
                "https://oauth2.googleapis.com/tokeninfo?access_token=google-access-token"
            )
            
            assert token_info.active == True
            assert token_info.email == "mode3.test@example.com"
    
    @pytest.mark.asyncio
    async def test_mode3_expired_token_error(self, google_relay_environment):
        """Test Mode 3: Expired tokens raise TokenExpiredError"""
        from percolate.api.auth.server import OAuthServer
        from percolate.api.auth.models import TokenExpiredError
        
        server = OAuthServer(BASE_URL)
        provider = server.providers["google"]
        
        with patch('httpx.AsyncClient') as mock_client:
            # Mock expired token response
            mock_response = Mock()
            mock_response.status_code = 401
            mock_response.json.return_value = {
                "error": "invalid_token",
                "error_description": "Token has been expired or revoked."
            }
            
            mock_client_instance = AsyncMock()
            mock_client_instance.get.return_value = mock_response
            mock_client.return_value.__aenter__.return_value = mock_client_instance
            
            # Should raise TokenExpiredError
            with pytest.raises(TokenExpiredError):
                await provider.validate("expired-google-token")


class TestModeDetection:
    """Test automatic mode detection based on environment"""
    
    @pytest.mark.asyncio
    async def test_default_mode_is_legacy(self):
        """Test that default mode is legacy bearer token"""
        # Clear any auth env vars
        for key in ["AUTH_MODE", "AUTH_PROVIDER"]:
            if key in os.environ:
                del os.environ[key]
        
        from percolate.api.auth.server import OAuthServer
        from percolate.api.auth.providers import BearerTokenProvider
        
        server = OAuthServer(BASE_URL)
        
        # Should have bearer provider only
        assert "bearer" in server.providers
        assert isinstance(server.providers["bearer"], BearerTokenProvider)
        assert "percolate" not in server.providers
    
    @pytest.mark.asyncio
    async def test_percolate_mode_detection(self):
        """Test AUTH_MODE=percolate activates JWT provider"""
        os.environ["AUTH_MODE"] = "percolate"
        
        try:
            from percolate.api.auth.server import OAuthServer
            from percolate.api.auth.jwt_provider import PercolateJWTProvider
            
            server = OAuthServer(BASE_URL)
            
            # Should have JWT provider
            assert "percolate" in server.providers
            assert isinstance(server.providers["percolate"], PercolateJWTProvider)
            # Bearer should also be JWT provider
            assert isinstance(server.providers["bearer"], PercolateJWTProvider)
        finally:
            del os.environ["AUTH_MODE"]
    
    @pytest.mark.asyncio
    async def test_external_provider_detection(self):
        """Test AUTH_PROVIDER=google activates relay mode"""
        os.environ["AUTH_PROVIDER"] = "google"
        os.environ["GOOGLE_OAUTH_CLIENT_ID"] = "test"
        os.environ["GOOGLE_OAUTH_CLIENT_SECRET"] = "test"
        
        try:
            from percolate.api.auth.server import OAuthServer
            from percolate.api.auth.providers import GoogleOAuthRelayProvider
            
            server = OAuthServer(BASE_URL)
            
            # Should have relay provider
            assert "google" in server.providers
            assert isinstance(server.providers["google"], GoogleOAuthRelayProvider)
        finally:
            for key in ["AUTH_PROVIDER", "GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"]:
                if key in os.environ:
                    del os.environ[key]


if __name__ == "__main__":
    # Run tests
    pytest.main([__file__, "-v"])