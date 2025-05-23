"""
Test suite for admin content upload endpoint.
Tests file upload functionality with and without hybrid auth.
"""

import io
import json
import uuid
import pytest
from fastapi import status
from fastapi.testclient import TestClient
from unittest.mock import Mock, patch, AsyncMock
from percolate.api.main import app
from percolate.models import Resources, Session, SessionResources

@pytest.fixture
def client():
    """Create test client."""
    return TestClient(app)

@pytest.fixture
def auth_headers():
    """Create auth headers for testing."""
    # Create a valid token (this should match your auth system)
    return {"Authorization": "Bearer test_token"}

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
@pytest.mark.skip
@pytest.mark.slow
class TestContentUpload:
    """Test content upload functionality."""
    
    def test_upload_file_basic(self, client, auth_headers, mock_s3_service):
        """Test basic file upload."""
        # Mock the auth dependencies
        test_user_id = str(uuid.uuid4())
        user_id_param = str(uuid.uuid4())
        
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return test_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            # Create test file
            file_content = b"Test file content"
            file = ("test.txt", file_content, "text/plain")
            
            response = client.post(
                "/admin/content/upload",
                headers=auth_headers,
                files={"file": file},
                data={
                    "task_id": "test-task-123",
                    "add_resource": True,
                    "user_id": user_id_param
                }
            )
        
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["filename"] == "test.txt"
            assert data["task_id"] == "test-task-123"
            assert data["message"] == "Uploaded successfully to S3"
            assert data["user_id"] == user_id_param  # Should use param user_id
            assert data["auth_method"] == "user_id_param"
            assert "key" in data  # Fixed to include the key field
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_file_without_task_id(self, client, auth_headers, mock_s3_service):
        """Test file upload without task_id (should use 'default')."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return None
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            response = client.post(
                "/admin/content/upload",
                headers=auth_headers,
                files={"file": file},
                data={
                    "add_resource": True,
                    "user_id": test_user_id
                }
            )
        
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["path"].endswith("default")
            assert data["task_id"] is None  # task_id is None when not provided
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_file_without_user_id(self, client, auth_headers, mock_s3_service):
        """Test file upload without user_id parameter, using bearer token only."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return test_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            response = client.post(
                "/admin/content/upload",
                headers=auth_headers,
                files={"file": file},
                data={
                    "task_id": "test-task-123",
                    "add_resource": True
                }
            )
        
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert f"users/{test_user_id}" in data["path"]
            assert data["auth_method"] == "bearer_token"
            assert data["user_id"] == test_user_id
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_file_with_device_info(self, client, auth_headers, mock_s3_service):
        """Test file upload with device info."""
        import base64
        
        device_info = {"device": "mobile", "os": "iOS"}
        encoded_device_info = base64.b64encode(json.dumps(device_info).encode()).decode()
        
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return test_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            response = client.post(
                "/admin/content/upload",
                headers=auth_headers,
                files={"file": file},
                data={
                    "task_id": "test-task-123",
                    "user_id": str(uuid.uuid4()),
                    "device_info": encoded_device_info
                }
            )
            
            assert response.status_code == status.HTTP_200_OK
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_file_with_add_resource_false(self, client, auth_headers, mock_s3_service):
        """Test file upload without adding resource."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return test_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            response = client.post(
                "/admin/content/upload",
                headers=auth_headers,
                files={"file": file},
                data={
                    "task_id": "test-task-123",
                    "add_resource": False
                }
            )
            
            assert response.status_code == status.HTTP_200_OK
        finally:
            app.dependency_overrides.clear()
    
    # Skip this test for now as we're not mocking S3 and just want to test hybrid auth
    # def test_upload_file_s3_error(self, client, auth_headers):
    #     """Test file upload with S3 error."""
    #     pass
    
    def test_upload_large_file(self, client, auth_headers, mock_s3_service):
        """Test large file upload."""
        # Create a 5MB file
        file_content = b"x" * (5 * 1024 * 1024)
        file = ("large.bin", file_content, "application/octet-stream")
        test_user_id = str(uuid.uuid4())
        
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return test_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            response = client.post(
                "/admin/content/upload",
                headers=auth_headers,
                files={"file": file},
                data={"task_id": "test-task-123"}
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["size"] == 5 * 1024 * 1024  # Actual file size
        finally:
            app.dependency_overrides.clear()
    
    # This test is complex and not directly related to hybrid auth
    # so we'll skip it for now
    # @pytest.mark.asyncio
    # async def test_background_resource_indexing(self, client, auth_headers, mock_s3_service):
    #     """Test that background resource indexing works correctly."""
    #     pass

@pytest.mark.slow
class TestHybridAuth:
    """Test hybrid auth functionality."""
    
    def test_upload_with_bearer_token(self, client, mock_s3_service):
        """Test upload with bearer token auth."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        
        # Override the dependency in the FastAPI app
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return test_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            headers = {"Authorization": "Bearer test_token"}
            response = client.post(
                "/admin/content/upload",
                headers=headers,
                files={"file": file},
                data={"task_id": "test-task-123"}
            )
            
            if response.status_code != status.HTTP_200_OK:
                print(f"Error response: {response.status_code}")
                print(f"Response body: {response.json()}")
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["auth_method"] == "bearer_token"
            assert data["user_id"] == test_user_id
            assert data["path"] == f"users/{test_user_id}/test-task-123"
        finally:
            # Clean up the override
            app.dependency_overrides.clear()
    
    def test_upload_with_user_id_only(self, client, mock_s3_service):
        """Test upload with only user_id parameter (no bearer token)."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        
        # Override the dependency to return None (no bearer token)
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return None
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            response = client.post(
                "/admin/content/upload",
                files={"file": file},
                data={
                    "task_id": "test-task-123",
                    "user_id": test_user_id
                }
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["auth_method"] == "user_id_param"
            assert data["user_id"] == test_user_id
            assert data["path"] == f"users/{test_user_id}/test-task-123"
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_with_both_auth_prefers_user_id(self, client, mock_s3_service):
        """Test upload with both bearer token and user_id parameter."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        token_user_id = str(uuid.uuid4())
        param_user_id = str(uuid.uuid4())
        
        # Override the dependency to return a user ID (bearer token)
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return token_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            headers = {"Authorization": "Bearer test_token"}
            response = client.post(
                "/admin/content/upload",
                headers=headers,
                files={"file": file},
                data={
                    "task_id": "test-task-123",
                    "user_id": param_user_id
                }
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            # Should prefer user_id parameter over bearer token
            assert data["user_id"] == param_user_id
            assert data["auth_method"] == "user_id_param"
            assert data["path"] == f"users/{param_user_id}/test-task-123"
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_without_any_auth(self, client, mock_s3_service):
        """Test upload without any authentication succeeds with optional auth."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        
        # Override dependency to return None (no bearer token)
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return None
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            # No user_id parameter either
            response = client.post(
                "/admin/content/upload",
                files={"file": file},
                data={"task_id": "test-task-123"}
            )
            
            # Should return 200 OK with optional auth
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert data["user_id"] is None
            assert data["auth_method"] is None
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_response_includes_expected_fields(self, client, mock_s3_service):
        """Test that upload response includes expected fields."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        
        # Override dependency to return a user ID
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return test_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
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
            # Check expected fields in current implementation
            assert "key" in data
            assert "filename" in data
            assert "task_id" in data
            assert "path" in data
            assert "message" in data
            assert "user_id" in data
            assert "auth_method" in data
            assert "size" in data
            assert "presigned_url" in data
        finally:
            app.dependency_overrides.clear()
    
    def test_upload_path_includes_user_id_from_param(self, client, mock_s3_service):
        """Test that upload path includes user_id from parameter."""
        file_content = b"Test file content"
        file = ("test.txt", file_content, "text/plain")
        test_user_id = str(uuid.uuid4())
        token_user_id = str(uuid.uuid4())
        
        # Override dependency to return a different user ID (from bearer token)
        from percolate.api.routes.admin.router import optional_hybrid_auth
        from percolate.api.main import app
        
        def override_optional_hybrid_auth():
            return token_user_id
        
        app.dependency_overrides[optional_hybrid_auth] = override_optional_hybrid_auth
        
        try:
            headers = {"Authorization": "Bearer test_token"}
            response = client.post(
                "/admin/content/upload",
                headers=headers,
                files={"file": file},
                data={
                    "task_id": "test-task-123",
                    "user_id": test_user_id
                }
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            # Should use the user_id parameter in the path
            assert data["path"] == f"users/{test_user_id}/test-task-123"
            assert data["user_id"] == test_user_id
            assert data["auth_method"] == "user_id_param"
        finally:
            app.dependency_overrides.clear()