import pytest
import asyncio
from unittest.mock import Mock, patch, MagicMock
from fastapi.testclient import TestClient
from percolate.api.routes.admin.router import router
from percolate.services import PostgresService
import percolate as p8
import uuid
import io

# Create test client
from fastapi import FastAPI
app = FastAPI()
app.include_router(router, prefix="/admin")
client = TestClient(app)

@pytest.fixture
def mock_auth():
    """Mock authentication to return a test user"""
    with patch('percolate.api.routes.admin.router.optional_hybrid_auth') as mock:
        mock.return_value = "test-user-id"
        yield mock

@pytest.fixture
def mock_s3_service():
    """Mock S3Service to avoid actual S3 operations"""
    with patch('percolate.api.routes.admin.router.S3Service') as mock:
        instance = mock.return_value
        instance.default_bucket = "test-bucket"
        instance.upload_filebytes_to_uri.return_value = {
            "uri": "s3://test-bucket/users/test-user-id/test-task/test.txt",
            "name": "test.txt",
            "size": 100,
            "content_type": "text/plain",
            "last_modified": "2024-01-01T00:00:00Z",
            "etag": "test-etag"
        }
        instance.get_presigned_url_for_uri.return_value = "https://test-presigned-url"
        yield instance

@pytest.fixture
def mock_filesystem_service():
    """Mock FileSystemService to avoid actual file operations"""
    with patch('percolate.api.routes.admin.router.FileSystemService') as mock:
        instance = mock.return_value
        # Create mock resources with groupid attribute
        mock_resource = MagicMock()
        mock_resource.id = str(uuid.uuid4())
        mock_resource.groupid = None  # Will be set by the endpoint
        mock_resource.model_dump.return_value = {"id": mock_resource.id, "groupid": None}
        
        instance.read_chunks.return_value = [mock_resource]
        yield instance, mock_resource

@pytest.fixture
def mock_postgres_service():
    """Mock PostgresService for database operations"""
    with patch('percolate.api.routes.admin.router.PostgresService') as mock:
        instance = mock.return_value
        instance.check_entity_exists_by_name.return_value = True
        yield instance

@pytest.fixture  
def mock_repository():
    """Mock p8.repository to track database saves"""
    saved_records = []
    
    def mock_update_records(records):
        if not isinstance(records, list):
            records = [records]
        saved_records.extend(records)
        return [{"id": getattr(r, 'id', str(uuid.uuid4())), "groupid": getattr(r, 'groupid', None)} for r in records]
    
    with patch('percolate.api.routes.admin.router.p8.repository') as mock:
        mock_repo = MagicMock()
        mock_repo.update_records = mock_update_records
        mock.return_value = mock_repo
        mock.saved_records = saved_records
        yield mock

@pytest.fixture
def mock_model_loader():
    """Mock try_load_model to return a mock Resources model"""
    with patch('percolate.api.routes.admin.router.try_load_model') as mock:
        mock_model = MagicMock()
        mock_model.__name__ = "Resources"
        mock.return_value = mock_model
        yield mock_model

@pytest.mark.asyncio
async def test_content_upload_with_groupid(
    mock_auth, 
    mock_s3_service, 
    mock_filesystem_service, 
    mock_postgres_service,
    mock_repository,
    mock_model_loader
):
    """Test that groupid parameter is properly passed to resources"""
    
    # Unpack the filesystem service mock
    fs_service, mock_resource = mock_filesystem_service
    
    # Create a test file
    test_file_content = b"Test file content"
    test_file = io.BytesIO(test_file_content)
    
    # Test groupid value
    test_groupid = "test-group-123"
    
    # Make the request with groupid
    response = client.post(
        "/admin/content/upload",
        files={"file": ("test.txt", test_file, "text/plain")},
        data={
            "task_id": "test-task",
            "add_resource": "true",
            "groupid": test_groupid,
            "namespace": "public",
            "entity_name": "Resources"
        }
    )
    
    # Check response
    assert response.status_code == 200
    data = response.json()
    assert data["filename"] == "test.txt"
    assert data["message"] == "Uploaded successfully to S3"
    
    # Wait for background task to complete
    await asyncio.sleep(0.1)
    
    # Verify that groupid was set on the resource
    assert mock_resource.groupid == test_groupid
    
    # Verify the resource was saved with groupid
    # The repository mock should have been called with resources that have groupid set
    assert len(mock_repository.saved_records) > 0
    
    # Check that at least one saved resource has the groupid
    saved_with_groupid = False
    for record in mock_repository.saved_records:
        if hasattr(record, 'groupid') and record.groupid == test_groupid:
            saved_with_groupid = True
            break
    
    assert saved_with_groupid, "Resource should have been saved with groupid"

@pytest.mark.asyncio
async def test_content_upload_without_groupid(
    mock_auth,
    mock_s3_service,
    mock_filesystem_service,
    mock_postgres_service,
    mock_repository,
    mock_model_loader
):
    """Test that upload works without groupid (backwards compatibility)"""
    
    # Unpack the filesystem service mock
    fs_service, mock_resource = mock_filesystem_service
    
    # Create a test file
    test_file_content = b"Test file content"
    test_file = io.BytesIO(test_file_content)
    
    # Make the request without groupid
    response = client.post(
        "/admin/content/upload",
        files={"file": ("test.txt", test_file, "text/plain")},
        data={
            "task_id": "test-task",
            "add_resource": "true",
            "namespace": "public",
            "entity_name": "Resources"
        }
    )
    
    # Check response
    assert response.status_code == 200
    data = response.json()
    assert data["filename"] == "test.txt"
    
    # Wait for background task to complete
    await asyncio.sleep(0.1)
    
    # Verify that groupid was not set (remains None)
    assert mock_resource.groupid is None

@pytest.mark.asyncio
async def test_query_resources_with_groupid():
    """Test querying resources by groupid using PostgresService"""
    
    # This test demonstrates how to query resources with a specific groupid
    # In a real scenario, after uploading with groupid, you would query like this:
    
    test_groupid = "test-group-123"
    
    # Mock the PostgresService select method
    with patch.object(PostgresService, 'select') as mock_select:
        mock_select.return_value = [
            {"id": "resource-1", "name": "file1.txt", "groupid": test_groupid},
            {"id": "resource-2", "name": "file2.txt", "groupid": test_groupid}
        ]
        
        # Query resources by groupid
        pg_service = PostgresService()
        resources = pg_service.select(groupid=test_groupid)
        
        # Verify the query was made with groupid
        mock_select.assert_called_once_with(groupid=test_groupid)
        
        # Verify results
        assert len(resources) == 2
        assert all(r["groupid"] == test_groupid for r in resources)