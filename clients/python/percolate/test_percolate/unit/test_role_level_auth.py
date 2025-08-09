"""
Unit tests for role_level assignment in auth dependencies
"""

import pytest
from unittest.mock import patch, MagicMock
from percolate.api.routes.auth import hybrid_auth_with_role
from fastapi import Request
from fastapi.security import HTTPAuthorizationCredentials


@pytest.mark.asyncio
async def test_hybrid_auth_with_role_returns_role_level():
    """Test that hybrid_auth_with_role returns both user_id and role_level"""
    
    with patch('percolate.api.routes.auth.get_api_key') as mock_get_api_key, \
         patch('percolate.api.routes.auth.get_user_with_role_from_email') as mock_get_user_role:
        
        # Mock successful API key validation
        mock_get_api_key.return_value = "test_api_key"
        
        # Mock user resolution with role_level
        mock_get_user_role.return_value = ("user-id-123", 10)  # user_id, role_level=10
        
        # Mock request with bearer token and email header
        request = MagicMock(spec=Request)
        request.headers = {
            'Authorization': 'Bearer test_token',
            'X-User-Email': 'test@example.com'
        }
        request.cookies = {}
        request.session = {}
        request.query_params = {}
        
        # Mock credentials
        credentials = HTTPAuthorizationCredentials(scheme="bearer", credentials="test_token")
        
        # Call the hybrid_auth_with_role dependency
        auth_instance = hybrid_auth_with_role
        user_id, role_level = await auth_instance(request, credentials)
        
        # Verify the result
        assert user_id == "user-id-123"
        assert role_level == 10
        
        # Verify the mocks were called correctly
        mock_get_api_key.assert_called_once()
        mock_get_user_role.assert_called_once_with('test@example.com')


@pytest.mark.asyncio
async def test_hybrid_auth_with_role_no_role_level():
    """Test that users without role_level get None"""
    
    with patch('percolate.api.routes.auth.get_api_key') as mock_get_api_key, \
         patch('percolate.api.routes.auth.get_user_with_role_from_email') as mock_get_user_role:
        
        # Mock successful API key validation
        mock_get_api_key.return_value = "test_api_key"
        
        # Mock user resolution with no role_level
        mock_get_user_role.return_value = ("user-id-456", None)
        
        # Create mock request
        request = MagicMock()
        request.headers = {'X-User-Email': 'noRole@example.com'}
        request.cookies = {}
        request.session = {}
        request.query_params = {}
        
        credentials = HTTPAuthorizationCredentials(scheme="bearer", credentials="test_token")
        
        # Call the auth dependency
        auth_instance = hybrid_auth_with_role
        user_id, role_level = await auth_instance(request, credentials)
        
        # Verify the result
        assert user_id == "user-id-456"
        assert role_level is None


@pytest.mark.asyncio
async def test_hybrid_auth_with_role_session_auth():
    """Test that session authentication also returns role_level"""
    
    with patch('percolate.api.routes.auth.get_user_from_session') as mock_get_session, \
         patch('percolate.services.PostgresService') as mock_pg:
        
        # Mock session returns user_id
        mock_get_session.return_value = "session-user-123"
        
        # Mock PostgresService to return role_level
        mock_pg_instance = MagicMock()
        mock_pg_instance.execute.return_value = [{'role_level': 5}]
        mock_pg.return_value = mock_pg_instance
        
        # Create mock request with session
        request = MagicMock()
        request.session = {'user_id': 'session-user-123'}
        request.cookies = {'session': 'test-session-cookie'}
        request.query_params = {}
        request.headers = {}
        
        # Call hybrid_auth_with_role with no credentials (session auth)
        auth_instance = hybrid_auth_with_role
        user_id, role_level = await auth_instance(request, None)
        
        # Verify results
        assert user_id == "session-user-123"
        assert role_level == 5
        
        # Verify database was queried
        mock_pg_instance.execute.assert_called_once_with(
            'SELECT role_level FROM p8."User" WHERE id::TEXT = %s LIMIT 1',
            data=("session-user-123",)
        )


@pytest.mark.asyncio
async def test_hybrid_auth_with_role_query_param():
    """Test that user_id from query params also gets role_level"""
    
    with patch('percolate.api.routes.auth.get_api_key') as mock_get_api_key, \
         patch('percolate.services.PostgresService') as mock_pg:
        
        # Mock successful API key validation
        mock_get_api_key.return_value = "test_api_key"
        
        # Mock PostgresService to return role_level
        mock_pg_instance = MagicMock()
        mock_pg_instance.execute.return_value = [{'role_level': 7}]
        mock_pg.return_value = mock_pg_instance
        
        # Create mock request with user_id in query params
        request = MagicMock()
        request.query_params = {'user_id': 'query-user-789'}
        request.headers = {}
        request.cookies = {}
        request.session = {}
        
        credentials = HTTPAuthorizationCredentials(scheme="bearer", credentials="test_token")
        
        # Call the auth dependency
        auth_instance = hybrid_auth_with_role
        user_id, role_level = await auth_instance(request, credentials)
        
        # Verify results
        assert user_id == "query-user-789"
        assert role_level == 7
        
        # Verify database was queried
        mock_pg_instance.execute.assert_called_once_with(
            'SELECT role_level FROM p8."User" WHERE id::TEXT = %s LIMIT 1',
            data=("query-user-789",)
        )