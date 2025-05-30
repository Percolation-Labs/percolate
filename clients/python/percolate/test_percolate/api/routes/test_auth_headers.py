"""
Test suite for hybrid authentication with email headers.
"""

import pytest
from fastapi import status
from fastapi.testclient import TestClient
from unittest.mock import patch
from percolate.api.main import app


@pytest.fixture
def client():
    """Create test client."""
    return TestClient(app)


@pytest.mark.slow
class TestAuthHeaders:
    """Test hybrid authentication with various email headers."""
    
    def test_x_user_email_header(self, client):
        """Test authentication with X-User-Email header."""
        # Mock the get_user_from_email function to return a user
        with patch('percolate.api.routes.auth.utils.get_user_from_email') as mock_get_user:
            mock_get_user.return_value = {"id": "test-user-123", "email": "test@example.com"}
            
            headers = {
                "Authorization": "Bearer test_token",
                "X-User-Email": "test@example.com"
            }
            
            # Override the API key validation
            from percolate.api.routes.auth import get_api_key
            from percolate.api.main import app
            
            def override_api_key():
                return "test_token"
                
            app.dependency_overrides[get_api_key] = override_api_key
            
            try:
                # Use entities endpoint for testing
                response = client.get("/entities/", headers=headers)
                
                assert response.status_code == status.HTTP_200_OK
                mock_get_user.assert_called_once_with("test@example.com")
            finally:
                app.dependency_overrides.clear()
    
    def test_x_openwebui_user_email_header(self, client):
        """Test authentication with X-OpenWebUI-User-Email header."""
        # Mock the get_user_from_email function to return a user
        with patch('percolate.api.routes.auth.utils.get_user_from_email') as mock_get_user:
            mock_get_user.return_value = {"id": "test-user-456", "email": "openwebui@example.com"}
            
            headers = {
                "Authorization": "Bearer test_token",
                "X-OpenWebUI-User-Email": "openwebui@example.com"
            }
            
            # Override the API key validation
            from percolate.api.routes.auth import get_api_key
            from percolate.api.main import app
            
            def override_api_key():
                return "test_token"
                
            app.dependency_overrides[get_api_key] = override_api_key
            
            try:
                # Use entities endpoint for testing
                response = client.get("/entities/", headers=headers)
                
                assert response.status_code == status.HTTP_200_OK
                mock_get_user.assert_called_once_with("openwebui@example.com")
            finally:
                app.dependency_overrides.clear()
    
    def test_lowercase_headers(self, client):
        """Test authentication with lowercase header variants."""
        # Mock the get_user_from_email function to return a user
        with patch('percolate.api.routes.auth.utils.get_user_from_email') as mock_get_user:
            mock_get_user.return_value = {"id": "test-user-789", "email": "lowercase@example.com"}
            
            headers = {
                "Authorization": "Bearer test_token",
                "x-openwebui-user-email": "lowercase@example.com"
            }
            
            # Override the API key validation
            from percolate.api.routes.auth import get_api_key
            from percolate.api.main import app
            
            def override_api_key():
                return "test_token"
                
            app.dependency_overrides[get_api_key] = override_api_key
            
            try:
                # Use entities endpoint for testing
                response = client.get("/entities/", headers=headers)
                
                assert response.status_code == status.HTTP_200_OK
                mock_get_user.assert_called_once_with("lowercase@example.com")
            finally:
                app.dependency_overrides.clear()
    
    def test_header_precedence(self, client):
        """Test header precedence when multiple email headers are provided."""
        # Mock the get_user_from_email function to return a user
        with patch('percolate.api.routes.auth.utils.get_user_from_email') as mock_get_user:
            mock_get_user.return_value = {"id": "test-user-precedence", "email": "first@example.com"}
            
            headers = {
                "Authorization": "Bearer test_token",
                "X-User-Email": "first@example.com",
                "X-OpenWebUI-User-Email": "second@example.com"
            }
            
            # Override the API key validation
            from percolate.api.routes.auth import get_api_key
            from percolate.api.main import app
            
            def override_api_key():
                return "test_token"
                
            app.dependency_overrides[get_api_key] = override_api_key
            
            try:
                # Use entities endpoint for testing
                response = client.get("/entities/", headers=headers)
                
                assert response.status_code == status.HTTP_200_OK
                # Should use the first non-empty header found
                mock_get_user.assert_called_once_with("first@example.com")
            finally:
                app.dependency_overrides.clear()