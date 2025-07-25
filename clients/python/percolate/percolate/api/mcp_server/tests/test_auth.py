"""Test authentication functionality"""

import pytest
from percolate_mcp.auth.bearer_auth import PercolateBearerAuth, get_auth_provider
from percolate_mcp.config import Settings


@pytest.mark.asyncio
async def test_bearer_auth_success():
    """Test successful bearer authentication"""
    auth = PercolateBearerAuth(token="test-token-123")
    
    result = await auth.authenticate({"bearer": "test-token-123"})
    
    assert result.success is True
    assert result.error is None


@pytest.mark.asyncio
async def test_bearer_auth_failure_wrong_token():
    """Test failed authentication with wrong token"""
    auth = PercolateBearerAuth(token="test-token-123")
    
    result = await auth.authenticate({"bearer": "wrong-token"})
    
    assert result.success is False
    assert result.error == "Invalid token"


@pytest.mark.asyncio
async def test_bearer_auth_failure_no_token():
    """Test failed authentication with no token"""
    auth = PercolateBearerAuth(token="test-token-123")
    
    result = await auth.authenticate({})
    
    assert result.success is False
    assert result.error == "No token provided in request"


@pytest.mark.asyncio  
async def test_bearer_auth_no_configured_token():
    """Test authentication when no token is configured"""
    auth = PercolateBearerAuth(token=None)
    
    result = await auth.authenticate({"bearer": "any-token"})
    
    assert result.success is False
    assert result.error == "No bearer token configured"


@pytest.mark.asyncio
async def test_bearer_auth_with_user_context(mock_settings):
    """Test authentication includes user context"""
    auth = PercolateBearerAuth(token="test-token-123")
    
    with pytest.mock.patch("percolate_mcp.auth.bearer_auth.get_settings", return_value=mock_settings):
        result = await auth.authenticate({"bearer": "test-token-123"})
    
    assert result.success is True
    assert result.user_id == "test-user"
    assert result.metadata["user_groups"] == "group1,group2"
    assert result.metadata["role_level"] == 5


def test_get_auth_provider_with_token(mock_settings):
    """Test auth provider creation with token"""
    with pytest.mock.patch("percolate_mcp.auth.bearer_auth.get_settings", return_value=mock_settings):
        provider = get_auth_provider()
    
    assert provider is not None
    assert isinstance(provider, PercolateBearerAuth)


def test_get_auth_provider_without_token():
    """Test auth provider returns None without token"""
    settings = Settings(percolate_token=None)
    
    with pytest.mock.patch("percolate_mcp.auth.bearer_auth.get_settings", return_value=settings):
        provider = get_auth_provider()
    
    assert provider is None