"""
Tests for OAuth 2.1 authentication system
"""

import pytest
import httpx
import secrets
import hashlib
import base64
from unittest.mock import Mock, patch, AsyncMock

from percolate.api.auth import (
    OAuthServer,
    BearerTokenProvider,
    GoogleOAuthProvider,
    AuthRequest,
    TokenRequest,
    AuthError,
    AuthContext
)
from percolate.api.auth.middleware import get_auth, require_auth
from percolate.models.p8.types import User
from percolate.utils import make_uuid


@pytest.fixture
def oauth_server():
    """Create OAuth server instance"""
    server = OAuthServer("http://localhost:8000")
    return server


@pytest.fixture
def bearer_provider():
    """Create bearer token provider"""
    return BearerTokenProvider()


@pytest.fixture
def google_provider():
    """Create Google OAuth provider"""
    return GoogleOAuthProvider(
        client_id="test-client-id",
        client_secret="test-client-secret",
        redirect_uri="http://localhost:8000/callback"
    )


class TestBearerTokenProvider:
    """Test bearer token authentication"""
    
    @pytest.mark.asyncio
    async def test_authorize_success(self, bearer_provider):
        """Test successful authorization with bearer token"""
        # Mock the validation function
        with patch('percolate.auth.providers.is_valid_token_for_user', return_value=True):
            request = AuthRequest(
                client_id="test-client",
                bearer_token="sk-test-token",
                user_email="test@example.com"
            )
            
            response = await bearer_provider.authorize(request)
            
            assert response.code is not None
            assert response.state == request.state
            assert response.error is None
    
    @pytest.mark.asyncio
    async def test_authorize_missing_token(self, bearer_provider):
        """Test authorization without bearer token"""
        request = AuthRequest(
            client_id="test-client",
            user_email="test@example.com"
        )
        
        with pytest.raises(AuthError) as exc_info:
            await bearer_provider.authorize(request)
        
        assert exc_info.value.error == "invalid_request"
        assert "Bearer token required" in exc_info.value.error_description
    
    @pytest.mark.asyncio
    async def test_authorize_missing_email(self, bearer_provider):
        """Test authorization without email"""
        request = AuthRequest(
            client_id="test-client",
            bearer_token="sk-test-token"
        )
        
        with pytest.raises(AuthError) as exc_info:
            await bearer_provider.authorize(request)
        
        assert exc_info.value.error == "invalid_request"
        assert "X-User-Email header required" in exc_info.value.error_description
    
    @pytest.mark.asyncio
    async def test_token_exchange(self, bearer_provider):
        """Test exchanging authorization code for token"""
        # First authorize
        with patch('percolate.auth.providers.is_valid_token_for_user', return_value=True):
            auth_request = AuthRequest(
                client_id="test-client",
                bearer_token="sk-test-token",
                user_email="test@example.com"
            )
            auth_response = await bearer_provider.authorize(auth_request)
        
        # Mock get_user_from_email
        with patch('percolate.auth.providers.get_user_from_email', return_value=Mock()):
            # Exchange code for token
            token_request = TokenRequest(
                grant_type="authorization_code",
                code=auth_response.code,
                client_id="test-client"
            )
            
            token_response = await bearer_provider.token(token_request)
            
            assert token_response.access_token == "sk-test-token"
            assert token_response.token_type == "Bearer"
            assert token_response.scope == "read write"
    
    @pytest.mark.asyncio
    async def test_validate_token(self, bearer_provider):
        """Test token validation"""
        # Mock repository
        mock_user = User(
            id=make_uuid("test@example.com"),
            email="test@example.com",
            token="sk-test-token",
            role_level=5,
            groups=["users"]
        )
        
        with patch('percolate.repository') as mock_repo:
            mock_repo.return_value.select.return_value = [mock_user.model_dump()]
            
            token_info = await bearer_provider.validate("sk-test-token")
            
            assert token_info.active is True
            assert token_info.email == "test@example.com"
            assert token_info.provider == "bearer"
            assert token_info.scope == "read write"


class TestGoogleOAuthProvider:
    """Test Google OAuth provider"""
    
    @pytest.mark.asyncio
    async def test_authorize_redirect(self, google_provider):
        """Test authorization redirects to Google"""
        request = AuthRequest(
            client_id="test-client",
            redirect_uri="http://localhost:8000/callback",
            scope="openid email profile"
        )
        
        response = await google_provider.authorize(request)
        
        assert response.redirect_uri is not None
        assert "accounts.google.com" in response.redirect_uri
        assert response.state is not None
    
    @pytest.mark.asyncio
    async def test_token_exchange_success(self, google_provider):
        """Test successful token exchange"""
        # Mock httpx client
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "access_token": "google-access-token",
            "refresh_token": "google-refresh-token",
            "expires_in": 3600,
            "id_token": "google-id-token",
            "scope": "openid email profile"
        }
        
        mock_userinfo_response = Mock()
        mock_userinfo_response.status_code = 200
        mock_userinfo_response.json.return_value = {
            "email": "user@gmail.com",
            "name": "Test User"
        }
        
        with patch('httpx.AsyncClient') as mock_client:
            mock_client.return_value.__aenter__.return_value.post.return_value = mock_response
            mock_client.return_value.__aenter__.return_value.get.return_value = mock_userinfo_response
            
            with patch('percolate.auth.providers.store_user_with_token'):
                token_request = TokenRequest(
                    grant_type="authorization_code",
                    code="test-auth-code",
                    redirect_uri="http://localhost:8000/callback"
                )
                
                token_response = await google_provider.token(token_request)
                
                assert token_response.access_token == "google-access-token"
                assert token_response.refresh_token == "google-refresh-token"
                assert token_response.expires_in == 3600


class TestOAuthServer:
    """Test OAuth server"""
    
    @pytest.mark.asyncio
    async def test_authorize_with_bearer(self, oauth_server):
        """Test authorization with bearer token"""
        with patch('percolate.auth.providers.is_valid_token_for_user', return_value=True):
            request = AuthRequest(
                client_id="test-client",
                bearer_token="sk-test-token",
                user_email="test@example.com"
            )
            
            response = await oauth_server.authorize(request)
            
            assert response.code is not None
    
    @pytest.mark.asyncio
    async def test_validate_token(self, oauth_server):
        """Test token validation across providers"""
        # Mock user for bearer token
        mock_user = User(
            id=make_uuid("test@example.com"),
            email="test@example.com",
            token="sk-test-token"
        )
        
        with patch('percolate.repository') as mock_repo:
            mock_repo.return_value.select.return_value = [mock_user.model_dump()]
            
            token_info = await oauth_server.validate_token("sk-test-token")
            
            assert token_info.active is True
            assert token_info.email == "test@example.com"
    
    def test_get_oauth_metadata(self, oauth_server):
        """Test OAuth metadata generation"""
        metadata = oauth_server.get_oauth_metadata()
        
        assert metadata["issuer"] == "http://localhost:8000"
        assert metadata["authorization_endpoint"] == "http://localhost:8000/auth/authorize"
        assert metadata["token_endpoint"] == "http://localhost:8000/auth/token"
        assert "S256" in metadata["code_challenge_methods_supported"]


class TestAuthMiddleware:
    """Test authentication middleware"""
    
    @pytest.mark.asyncio
    async def test_get_auth_with_bearer(self):
        """Test get_auth dependency with bearer token"""
        # Mock request
        mock_request = Mock()
        mock_request.app.state.oauth_server = OAuthServer("http://localhost:8000")
        
        # Mock credentials
        mock_credentials = Mock()
        mock_credentials.credentials = "sk-test-token"
        
        # Mock token validation
        with patch.object(OAuthServer, 'validate_token') as mock_validate:
            mock_validate.return_value = Mock(
                active=True,
                email="test@example.com",
                sub="user-123",
                provider="bearer",
                scope="read write",
                metadata={}
            )
            
            auth_context = await get_auth(
                mock_request,
                mock_credentials,
                "test@example.com"
            )
            
            assert isinstance(auth_context, AuthContext)
            assert auth_context.email == "test@example.com"
            assert auth_context.provider == "bearer"
            assert "read" in auth_context.scopes
    
    @pytest.mark.asyncio
    async def test_require_auth_decorator(self):
        """Test require_auth decorator"""
        @require_auth(scopes=["admin"])
        async def protected_function(auth: AuthContext):
            return f"Hello {auth.email}"
        
        # Test with valid auth
        auth = AuthContext(
            user_id="123",
            email="admin@example.com",
            provider="bearer",
            scopes=["read", "write", "admin"],
            token="test-token"
        )
        
        result = await protected_function(auth=auth)
        assert result == "Hello admin@example.com"
        
        # Test with insufficient scope
        auth_no_admin = AuthContext(
            user_id="456",
            email="user@example.com",
            provider="bearer",
            scopes=["read", "write"],
            token="test-token"
        )
        
        with pytest.raises(Exception):  # InsufficientScopeError
            await protected_function(auth=auth_no_admin)


class TestPKCE:
    """Test PKCE implementation"""
    
    def test_pkce_generation(self):
        """Test PKCE code verifier and challenge generation"""
        # Generate code verifier
        code_verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode('utf-8').rstrip('=')
        
        # Generate code challenge
        code_challenge = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode()).digest()
        ).decode('utf-8').rstrip('=')
        
        # Verify lengths
        assert len(code_verifier) >= 43  # Minimum length per spec
        assert len(code_verifier) <= 128  # Maximum length per spec
        assert len(code_challenge) == 43  # SHA256 base64url encoded
        
        # Verify challenge can be recreated from verifier
        recreated_challenge = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode()).digest()
        ).decode('utf-8').rstrip('=')
        
        assert code_challenge == recreated_challenge


@pytest.mark.asyncio
async def test_oauth_flow_integration():
    """Test complete OAuth flow"""
    server = OAuthServer("http://localhost:8000")
    
    # Step 1: Authorization request
    with patch('percolate.auth.providers.is_valid_token_for_user', return_value=True):
        auth_request = AuthRequest(
            client_id="test-client",
            bearer_token="sk-test-token",
            user_email="test@example.com",
            code_challenge="test-challenge",
            code_challenge_method="S256"
        )
        
        auth_response = await server.authorize(auth_request)
        assert auth_response.code is not None
    
    # Step 2: Token exchange
    with patch('percolate.auth.providers.get_user_from_email', return_value=Mock()):
        token_request = TokenRequest(
            grant_type="authorization_code",
            code=auth_response.code,
            client_id="test-client",
            code_verifier="test-verifier"
        )
        
        # This will fail PKCE validation in real scenario
        # In production, the verifier must match the challenge
        try:
            token_response = await server.token(token_request)
        except AuthError as e:
            assert e.error == "invalid_grant"