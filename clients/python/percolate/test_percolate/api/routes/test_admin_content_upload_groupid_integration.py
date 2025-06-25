import pytest
import asyncio
import uuid
import io
import time
from fastapi.testclient import TestClient
from percolate.api.main import app
from percolate.services import PostgresService
import percolate as p8

# Create test client with auth header
client = TestClient(app)
headers = {"Authorization": "Bearer postgres"}  # Default API token

@pytest.mark.integration
def test_content_upload_with_groupid_integration():
    """Integration test that verifies groupid is saved to the actual database"""
    
    # Generate unique identifiers for this test
    test_groupid = f"test-group-{uuid.uuid4()}"
    test_task_id = f"test-task-{uuid.uuid4()}"
    test_filename = f"test-{uuid.uuid4()}.txt"
    
    # Create test file content
    test_file_content = b"Test file content for groupid verification"
    test_file = io.BytesIO(test_file_content)
    
    # Make the upload request with groupid
    response = client.post(
        "/admin/content/upload",
        headers=headers,
        files={"file": (test_filename, test_file, "text/plain")},
        data={
            "task_id": test_task_id,
            "add_resource": "true",
            "groupid": test_groupid,
            "namespace": "p8",  # Use default namespace
            "entity_name": "Resources"
        }
    )
    
    # Check response
    assert response.status_code == 200
    data = response.json()
    assert data["filename"] == test_filename
    assert data["message"] == "Uploaded successfully to S3"
    
    # Wait for background task to complete (give it more time for real DB)
    time.sleep(3)
    
    # Query the database using PostgresService to verify groupid was saved
    from percolate.models.p8 import Resources
    pg_service = PostgresService(Resources)
    
    # Query by groupid
    resources = pg_service.select(groupid=test_groupid)
    
    # Verify we got results
    assert len(resources) > 0, f"No resources found with groupid={test_groupid}"
    
    # Verify all returned resources have the correct groupid
    for resource in resources:
        assert resource.get('groupid') == test_groupid, f"Resource groupid mismatch: {resource.get('groupid')} != {test_groupid}"
        assert test_filename in resource.get('name', ''), f"Resource name doesn't contain filename: {resource.get('name')}"
    
    print(f"✓ Successfully uploaded file with groupid={test_groupid}")
    print(f"✓ Found {len(resources)} resource(s) in database with correct groupid")
    
    # Clean up - delete the created resources
    for resource in resources:
        pg_service.execute(
            "DELETE FROM p8.\"Resources\" WHERE id = %s",
            data=(resource['id'],)
        )
    print(f"✓ Cleaned up test resources")


@pytest.mark.integration
def test_content_upload_without_groupid_integration():
    """Integration test that verifies upload works without groupid (backwards compatibility)"""
    
    # Generate unique identifiers
    test_task_id = f"test-task-{uuid.uuid4()}"
    test_filename = f"test-{uuid.uuid4()}.txt"
    
    # Create test file
    test_file_content = b"Test file content without groupid"
    test_file = io.BytesIO(test_file_content)
    
    # Make the upload request without groupid
    response = client.post(
        "/admin/content/upload",
        headers=headers,
        files={"file": (test_filename, test_file, "text/plain")},
        data={
            "task_id": test_task_id,
            "add_resource": "true",
            "namespace": "p8",
            "entity_name": "Resources"
        }
    )
    
    # Check response
    assert response.status_code == 200
    data = response.json()
    assert data["filename"] == test_filename
    
    # Wait for background task
    time.sleep(3)
    
    # Query the database to find our resource by name
    from percolate.models.p8 import Resources
    pg_service = PostgresService(Resources)
    
    # We can't query by groupid since we didn't set one, so let's query by name pattern
    all_resources = pg_service.execute(
        f"SELECT * FROM p8.resources WHERE name LIKE %s ORDER BY created_at DESC LIMIT 10",
        data=(f"%{test_filename}%",)
    )
    
    # Find our resource
    our_resource = None
    for resource in all_resources:
        if test_filename in resource.get('name', ''):
            our_resource = resource
            break
    
    assert our_resource is not None, f"Could not find uploaded resource with name containing {test_filename}"
    
    # Verify groupid is None (not set)
    assert our_resource.get('groupid') is None, f"Expected groupid to be None, got: {our_resource.get('groupid')}"
    
    print(f"✓ Successfully uploaded file without groupid")
    print(f"✓ Verified resource has no groupid set")
    
    # Clean up
    pg_service.execute(
        "DELETE FROM p8.\"Resources\" WHERE id = %s",
        data=(our_resource['id'],)
    )
    print(f"✓ Cleaned up test resource")


@pytest.mark.integration  
def test_query_resources_by_groupid():
    """Test that we can query resources by groupid after upload"""
    
    # Create multiple files with same groupid
    test_groupid = f"test-group-query-{uuid.uuid4()}"
    test_task_id = f"test-task-{uuid.uuid4()}"
    uploaded_files = []
    
    # Upload 3 files with the same groupid
    for i in range(3):
        test_filename = f"test-file-{i}-{uuid.uuid4()}.txt"
        test_file = io.BytesIO(f"Test content {i}".encode())
        
        response = client.post(
            "/admin/content/upload",
            headers=headers,
            files={"file": (test_filename, test_file, "text/plain")},
            data={
                "task_id": test_task_id,
                "add_resource": "true",
                "groupid": test_groupid,
                "namespace": "p8",
                "entity_name": "Resources"
            }
        )
        
        assert response.status_code == 200
        uploaded_files.append(test_filename)
    
    # Wait for all uploads to complete
    time.sleep(3)
    
    # Query by groupid
    from percolate.models.p8 import Resources
    pg_service = PostgresService(Resources)
    resources = pg_service.select(groupid=test_groupid)
    
    # We should have at least 3 resources (could be more if files were chunked)
    assert len(resources) >= 3, f"Expected at least 3 resources, got {len(resources)}"
    
    # Verify all have the correct groupid
    for resource in resources:
        assert resource.get('groupid') == test_groupid
    
    # Check that our uploaded files are represented
    resource_names = [r.get('name', '') for r in resources]
    found_files = 0
    for filename in uploaded_files:
        if any(filename in name for name in resource_names):
            found_files += 1
    
    assert found_files == 3, f"Expected to find all 3 uploaded files, found {found_files}"
    
    print(f"✓ Successfully uploaded 3 files with groupid={test_groupid}")
    print(f"✓ Query returned {len(resources)} resources with correct groupid")
    
    # Clean up
    for resource in resources:
        pg_service.delete_by_id(resource['id'])
    print(f"✓ Cleaned up all test resources")


if __name__ == "__main__":
    # Run tests directly
    print("Running integration tests for groupid functionality...")
    print("=" * 60)
    
    test_content_upload_with_groupid_integration()
    print("=" * 60)
    
    test_content_upload_without_groupid_integration()
    print("=" * 60)
    
    test_query_resources_by_groupid()
    print("=" * 60)
    
    print("\nAll tests passed! ✓")