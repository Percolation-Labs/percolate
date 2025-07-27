"""
Test Mode A: Bearer Token Authentication with X-User-Email header
"""

import os
import pytest
import httpx
from datetime import datetime, timedelta
import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid
from percolate.services import PostgresService


# Test configuration
TEST_EMAIL = "test@example.com"
TEST_TOKEN = "sk-test-1234567890abcdef"
TEST_USER_NAME = "Test User"
BASE_URL = os.environ.get("P8_API_ENDPOINT", "http://localhost:5008")


@pytest.fixture
def test_user():
    """Create a test user with bearer token"""
    # Create user with token
    user_id = make_uuid(TEST_EMAIL)
    user = User(
        id=user_id,
        name=TEST_USER_NAME,
        email=TEST_EMAIL,
        token=TEST_TOKEN,
        token_expiry=datetime.utcnow() + timedelta(days=365),  # Long-lived token
        role_level=10,  # Partner level
        groups=["test_group"]
    )
    
    # Save user to database
    user_repo = p8.repository(User)
    user_repo.upsert_records(user)
    
    yield user
    
    # Cleanup: Remove test user
    try:
        user_repo.delete_records(user)
    except:
        pass


@pytest.mark.asyncio
async def test_bearer_auth_with_header(test_user):
    """Test authentication with bearer token and X-User-Email header"""
    async with httpx.AsyncClient() as client:
        # Test with both headers
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}",
                "X-User-Email": TEST_EMAIL
            }
        )
        
        assert response.status_code == 200
        data = response.json()
        assert "entities" in data or "messages" in data


@pytest.mark.asyncio
async def test_bearer_auth_with_env_var(test_user):
    """Test authentication with bearer token and X_USER_EMAIL environment variable"""
    # Set environment variable
    os.environ["X_USER_EMAIL"] = TEST_EMAIL
    
    try:
        async with httpx.AsyncClient() as client:
            # Test with only Authorization header (email from env)
            response = await client.get(
                f"{BASE_URL}/auth/ping",
                headers={
                    "Authorization": f"Bearer {TEST_TOKEN}"
                }
            )
            
            assert response.status_code == 200
            data = response.json()
            assert "entities" in data or "messages" in data
    finally:
        # Clean up env var
        if "X_USER_EMAIL" in os.environ:
            del os.environ["X_USER_EMAIL"]


@pytest.mark.asyncio
async def test_bearer_auth_missing_email(test_user):
    """Test authentication fails without email"""
    async with httpx.AsyncClient() as client:
        # Test with only token, no email
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}"
            }
        )
        
        # Should fail without email
        assert response.status_code == 401


@pytest.mark.asyncio
async def test_bearer_auth_wrong_email(test_user):
    """Test authentication fails with wrong email"""
    async with httpx.AsyncClient() as client:
        # Test with wrong email
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}",
                "X-User-Email": "wrong@example.com"
            }
        )
        
        # Should fail with mismatched email
        assert response.status_code == 401


@pytest.mark.asyncio
async def test_bearer_auth_expired_token():
    """Test authentication fails with expired token"""
    # Create user with expired token
    user_id = make_uuid("expired@example.com")
    user = User(
        id=user_id,
        name="Expired User",
        email="expired@example.com",
        token="sk-expired-token",
        token_expiry=datetime.utcnow() - timedelta(days=1),  # Expired
        role_level=10
    )
    
    user_repo = p8.repository(User)
    user_repo.upsert_records(user)
    
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{BASE_URL}/auth/ping",
                headers={
                    "Authorization": "Bearer sk-expired-token",
                    "X-User-Email": "expired@example.com"
                }
            )
            
            # Should fail with expired token
            assert response.status_code == 401
            assert "token_expired" in response.text.lower()
    finally:
        # Cleanup
        user_repo.delete_records(user)


@pytest.mark.asyncio
async def test_mcp_auth_flow(test_user):
    """Test MCP authentication flow with bearer token"""
    async with httpx.AsyncClient() as client:
        # 1. Try MCP endpoint without auth
        response = await client.get(f"{BASE_URL}/mcp")
        assert response.status_code == 401
        assert "WWW-Authenticate" in response.headers
        
        # 2. Get well-known endpoint
        response = await client.get(f"{BASE_URL}/.well-known/oauth-protected-resource")
        assert response.status_code == 200
        data = response.json()
        assert "authorization_endpoint" in data
        
        # 3. Authorize with bearer token
        response = await client.get(
            f"{BASE_URL}/auth/authorize",
            params={
                "response_type": "code",
                "client_id": "test-client",
                "redirect_uri": "http://localhost:8080/callback"
            },
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}",
                "X-User-Email": TEST_EMAIL
            }
        )
        
        # Should get authorization code
        assert response.status_code == 200
        assert "code" in response.json()
        
        auth_code = response.json()["code"]
        
        # 4. Exchange code for token
        response = await client.post(
            f"{BASE_URL}/auth/token",
            data={
                "grant_type": "authorization_code",
                "code": auth_code,
                "client_id": "test-client"
            }
        )
        
        assert response.status_code == 200
        token_data = response.json()
        assert "access_token" in token_data
        assert token_data["access_token"] == TEST_TOKEN  # Should return same token


@pytest.mark.asyncio
async def test_auth_ping(test_user):
    """Test authentication ping endpoint"""
    async with httpx.AsyncClient() as client:
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}",
                "X-User-Email": TEST_EMAIL
            }
        )
        
        assert response.status_code == 200
        data = response.json()
        assert data["authenticated"] == True
        assert data["user"]["email"] == TEST_EMAIL


if __name__ == "__main__":
    # Run tests
    pytest.main([__file__, "-v"])