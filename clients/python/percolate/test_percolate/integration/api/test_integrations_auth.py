"""
Test suite for integrations router with hybrid authentication.
"""

import pytest
from fastapi import status
from fastapi.testclient import TestClient
from unittest.mock import Mock, patch, AsyncMock
from percolate.api.main import app


@pytest.fixture
def client():
    """Create test client."""
    return TestClient(app)

@pytest.mark.skip
@pytest.mark.slow
class TestIntegrationsAuth:
    """Test integrations router with hybrid authentication."""
    
    def test_web_search_with_bearer_token(self, client):
        """Test web search with bearer token authentication."""
        from percolate.api.routes.auth import hybrid_auth
        from percolate.api.main import app
        
        def override_auth():
            return None  # Bearer token returns None
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            # Mock the database call
            with patch('percolate.PostgresService') as mock_pg:
                mock_pg.return_value.execute.return_value = []
                
                headers = {"Authorization": "Bearer test_token"}
                response = client.post(
                    "/x/web/search",
                    headers=headers,
                    json={"query": "test search"}
                )
                
                assert response.status_code == status.HTTP_200_OK
                data = response.json()
                assert isinstance(data, list)
        finally:
            app.dependency_overrides.clear()
    
    def test_web_fetch_with_session(self, client):
        """Test web fetch with session authentication."""
        from percolate.api.routes.auth import hybrid_auth
        from percolate.api.main import app
        
        def override_auth():
            return "test-user-123"  # Session returns user ID
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            # Mock the requests call
            with patch('requests.get') as mock_get:
                mock_response = Mock()
                mock_response.content.decode.return_value = "<html><body>Test</body></html>"
                mock_get.return_value = mock_response
                
                response = client.post(
                    "/x/web/fetch",
                    json={"url": "https://example.com", "html_as_markdown": True}
                )
                
                assert response.status_code == status.HTTP_200_OK
                data = response.json()
                assert "Test" in data
        finally:
            app.dependency_overrides.clear()
    
    def test_integrations_without_auth_fails(self, client):
        """Test that integrations endpoints require authentication."""
        # Clear any overrides
        app.dependency_overrides.clear()
        
        # Mock the auth to raise 401
        from percolate.api.routes.auth import hybrid_auth
        from fastapi import HTTPException
        
        def override_auth():
            raise HTTPException(status_code=401, detail="Authentication required")
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            response = client.post(
                "/x/web/search",
                json={"query": "test"}
            )
            assert response.status_code == status.HTTP_401_UNAUTHORIZED
        finally:
            app.dependency_overrides.clear()
    
    def test_mail_fetch_with_auth(self, client):
        """Test mail fetch with authentication."""
        from percolate.api.routes.auth import hybrid_auth
        from percolate.api.main import app
        
        def override_auth():
            return "test-user-123"
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            # Mock the GmailService
            with patch('percolate.api.routes.integrations.services.GmailService') as mock_gmail:
                # Create an async mock
                async_mock = AsyncMock()
                async_mock.return_value = []
                mock_gmail.return_value.fetch_latest_emails = async_mock
                
                response = client.post(
                    "/x/mail/fetch",
                    json={
                        "limit": 5,
                        "since_iso_date": "2024-01-01T00:00:00",
                        "domain_filter": "example.com"
                    }
                )
                
                assert response.status_code == status.HTTP_200_OK
                data = response.json()
                assert isinstance(data, list)
        finally:
            app.dependency_overrides.clear()
    
    def test_calendar_fetch_with_auth(self, client):
        """Test calendar fetch with authentication."""
        from percolate.api.routes.auth import hybrid_auth
        from percolate.api.main import app
        
        def override_auth():
            return "test-user-123"
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            response = client.post(
                "/x/calendar/fetch",
                json={"query": "test"}
            )
            
            # This endpoint returns null (pass) but should authenticate
            assert response.status_code == status.HTTP_200_OK
        finally:
            app.dependency_overrides.clear()