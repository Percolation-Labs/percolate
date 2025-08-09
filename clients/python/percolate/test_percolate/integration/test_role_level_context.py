"""
Integration tests for role_level assignment in CallingContext
"""

import pytest
from unittest.mock import patch, MagicMock
from percolate.api.routes.auth import hybrid_auth_with_role
from percolate.api.routes.chat.router import handle_openai_request
from percolate.api.routes.chat.models import CompletionsRequestOpenApiFormat, Message
from percolate.services.llm.CallingContext import CallingContext
import os


@pytest.fixture
def mock_auth_deps():
    """Mock authentication dependencies"""
    with patch('percolate.api.routes.auth.get_api_key') as mock_get_api_key, \
         patch('percolate.api.routes.auth.get_user_with_role_from_email') as mock_get_user_role:
        
        # Mock successful API key validation
        mock_get_api_key.return_value = "test_api_key"
        
        # Mock user resolution with role_level
        mock_get_user_role.return_value = ("user-id-123", 10)  # user_id, role_level=10
        
        yield {
            'get_api_key': mock_get_api_key,
            'get_user_role': mock_get_user_role
        }


@pytest.mark.asyncio
async def test_completions_endpoint_sets_role_level(mock_auth_deps):
    """Test that completions endpoint properly sets role_level in CallingContext"""
    
    # Create a mock request
    from fastapi import Request
    from fastapi.security import HTTPAuthorizationCredentials
    
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
    
    # Test that the role_level is included in CallingContext
    # Create a test request
    test_request = CompletionsRequestOpenApiFormat(
        model="gpt-4",
        messages=[
            Message(role="system", content="You are a helpful assistant"),
            Message(role="user", content="Hello")
        ],
        stream=True
    )
    
    # Create params with role_level
    params = {
        'userid': user_id,
        'role_level': role_level,
        'session_id': 'test-session'
    }
    
    # Mock the language model to capture the context
    captured_context = None
    
    class MockLanguageModel:
        def __init__(self, model_name):
            self.model_name = model_name
            
        def _call_raw(self, messages, functions, context):
            nonlocal captured_context
            captured_context = context
            # Return a mock response that can be iterated
            class MockResponse:
                def iter_lines(self):
                    yield b'data: {"choices": [{"delta": {"content": "Hello"}}]}\n\n'
                    yield b'data: [DONE]\n\n'
            return MockResponse()
    
    # Call the handler with our mock
    with patch('percolate.services.llm.LanguageModel', MockLanguageModel):
        response = handle_openai_request(test_request, params)
    
    # Verify the context was created with role_level
    assert captured_context is not None
    assert isinstance(captured_context, CallingContext)
    assert captured_context.role_level == 10
    assert captured_context.username == user_id


@pytest.mark.asyncio 
async def test_session_auth_includes_role_level(mock_auth_deps):
    """Test that session authentication also properly loads role_level"""
    
    # Mock PostgresService for session lookup
    with patch('percolate.services.PostgresService') as mock_pg:
        # Mock the query result for user lookup by session
        mock_pg_instance = MagicMock()
        mock_pg_instance.execute.return_value = [{'role_level': 5}]
        mock_pg.return_value = mock_pg_instance
        
        # Mock get_user_from_session to return a user_id
        with patch('percolate.api.routes.auth.get_user_from_session') as mock_session:
            mock_session.return_value = "session-user-123"
            
            # Create mock request with session
            request = MagicMock()
            request.session = {'user_id': 'session-user-123'}
            request.cookies = {'session': 'test-session-cookie'}
            request.query_params = {}
            request.headers = {}
            
            # Call hybrid_auth_with_role
            auth_instance = hybrid_auth_with_role
            user_id, role_level = await auth_instance(request, None)
            
            # Verify results
            assert user_id == "session-user-123"
            assert role_level == 5
            
            # Verify the database was queried for role_level
            mock_pg_instance.execute.assert_called_with(
                'SELECT role_level FROM p8."User" WHERE id::TEXT = %s LIMIT 1',
                data=("session-user-123",)
            )


@pytest.mark.asyncio
async def test_no_role_level_returns_none():
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