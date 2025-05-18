"""
Simple test suite for admin content upload endpoint.
Tests basic authentication with bearer token and session.
"""

import pytest
from fastapi import status
from fastapi.testclient import TestClient
from unittest.mock import Mock, patch
from percolate.api.main import app


@pytest.fixture
def client():
    """Create test client."""
    return TestClient(app)


@pytest.fixture
def mock_s3_service():
    """Mock S3Service for testing."""
    with patch('percolate.services.S3Service') as mock:
        instance = Mock()
        instance.default_bucket = "test-bucket"
        instance.upload_filebytes_to_uri.return_value = {
            "uri": "s3://test-bucket/test/file.txt",
            "key": "test/file.txt",
            "name": "file.txt",
            "size": 1024,
            "content_type": "text/plain",
            "last_modified": "2024-01-01T00:00:00",
            "etag": "test-etag",
            "status": "success"
        }
        instance.get_presigned_url_for_uri.return_value = "https://presigned-url"
        mock.return_value = instance
        yield instance


@pytest.mark.slow
class TestContentUploadAuth:
    """Test content upload with basic authentication modes."""
    
    def test_upload_with_bearer_token(self, client, mock_s3_service):
        """Test file upload with bearer token authentication."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        
        # Mock the auth to return a user ID from bearer token
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_auth():
            return "test-user-123"  # Return user ID from bearer token
            
        app.dependency_overrides[optional_hybrid_auth] = override_auth
        
        try:
            headers = {"Authorization": "Bearer test_token"}
            response = client.post(
                "/admin/content/upload",
                headers=headers,
                files={"file": file},
                data={"task_id": "test-task-123"}
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["filename"] == "test.txt"
            assert data["task_id"] == "test-task-123"
            assert data["user_id"] == "test-user-123"
            assert data["message"] == "Uploaded successfully to S3"
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_with_session_auth(self, client, mock_s3_service):
        """Test file upload with session authentication."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        
        # Mock the auth to return a user ID from session
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_auth():
            return "session-user-456"  # Return user ID from session
            
        app.dependency_overrides[optional_hybrid_auth] = override_auth
        
        try:
            # No Authorization header, just session cookie
            response = client.post(
                "/admin/content/upload",
                files={"file": file},
                data={"task_id": "test-task-456"}
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["filename"] == "test.txt"
            assert data["task_id"] == "test-task-456"
            assert data["user_id"] == "session-user-456"
            assert data["message"] == "Uploaded successfully to S3"
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_without_auth(self, client, mock_s3_service):
        """Test file upload without authentication (anonymous upload)."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        
        # Mock the auth to return None (no authentication)
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_auth():
            return None  # No authentication
            
        app.dependency_overrides[optional_hybrid_auth] = override_auth
        
        try:
            response = client.post(
                "/admin/content/upload",
                files={"file": file},
                data={"task_id": "anonymous-task"}
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["filename"] == "test.txt"
            assert data["task_id"] == "anonymous-task"
            assert data["user_id"] is None  # Anonymous upload
            assert data["path"] == "anonymous-task"  # No user prefix
            assert data["message"] == "Uploaded successfully to S3"
        finally:
            app.dependency_overrides.clear()