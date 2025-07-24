import pytest
import os
import uuid
import percolate as p8
from percolate.models.p8.types import Resources
from percolate.services import PostgresService
from percolate.utils import get_iso_timestamp
import typing


class TestResources:
    """Test suite for Resources model database operations."""
    
    @classmethod
    def setup_class(cls):
        """Set up test environment variables."""
        os.environ['P8_PG_HOST'] = 'eepis.percolationlabs.ai'
        os.environ['P8_PG_PORT'] = '5434'
        os.environ['P8_PG_PASSWORD'] = os.environ.get('P8_TEST_BEARER_TOKEN', '')
        
    @pytest.fixture
    def test_user_id(self):
        """Get the test user ID from the database."""
        pg = PostgresService()
        query = "SELECT id FROM p8.\"User\" WHERE email = %s LIMIT 1"
        result = pg.execute(query, data=('amartey@gmail.com',))
        if result:
            return str(result[0]['id'])
        else:
            # If test user doesn't exist, we'll use a dummy UUID
            return str(uuid.uuid4())
    
    @pytest.fixture
    def sample_resources(self, test_user_id) -> typing.List[Resources]:
        """Create sample resources for testing."""
        resources = []
        base_timestamp = get_iso_timestamp()
        
        for i in range(5):
            resource = Resources(
                name=f"Test Resource {i}",
                category="test",
                content=f"This is test content for resource {i}",
                uri=f"https://example.com/test-{i}.txt",
                ordinal=i,
                userid=test_user_id,
                metadata={"test": True, "index": i}
            )
            resources.append(resource)
            
        return resources
    
    @pytest.mark.slow
    @pytest.mark.skipif(
        not os.environ.get('P8_TEST_BEARER_TOKEN'),
        reason="Database credentials not available"
    )
    def test_get_recent_uploads_by_user(self, test_user_id, sample_resources):
        """Test the get_recent_uploads_by_user method."""
        # First, insert some test resources
        pg = PostgresService(model=Resources)
        
        # Insert sample resources
        for resource in sample_resources:
            try:
                pg.add_record(resource.model_dump())
            except Exception as e:
                # Skip if record already exists
                print(f"Skipping insert for {resource.uri}: {e}")
        
        # Test the new method with default limit
        recent_uploads = Resources.get_recent_uploads_by_user(
            user_id=test_user_id,
            limit=3
        )
        
        # Assertions
        assert isinstance(recent_uploads, list), "Result should be a list"
        assert len(recent_uploads) <= 3, "Should return at most 3 records"
        
        # Check that results are for the correct user
        for upload in recent_uploads:
            assert str(upload['userid']) == test_user_id, "All results should be for the test user"
        
        # Check ordering (most recent first)
        if len(recent_uploads) > 1:
            for i in range(len(recent_uploads) - 1):
                assert recent_uploads[i]['created_at'] >= recent_uploads[i + 1]['created_at'], \
                    "Results should be ordered by created_at DESC"
    
    @pytest.mark.slow
    @pytest.mark.skipif(
        not os.environ.get('P8_TEST_BEARER_TOKEN'),
        reason="Database credentials not available"
    )
    def test_get_recent_uploads_by_user_with_custom_limit(self, test_user_id):
        """Test the get_recent_uploads_by_user method with custom limit."""
        # Test with custom limit
        recent_uploads = Resources.get_recent_uploads_by_user(
            user_id=test_user_id,
            limit=1
        )
        
        assert isinstance(recent_uploads, list), "Result should be a list"
        assert len(recent_uploads) <= 1, "Should return at most 1 record"
    
    @pytest.mark.slow
    @pytest.mark.skipif(
        not os.environ.get('P8_TEST_BEARER_TOKEN'),
        reason="Database credentials not available"
    )
    def test_get_recent_uploads_by_user_no_results(self):
        """Test the get_recent_uploads_by_user method when user has no uploads."""
        # Use a random UUID that shouldn't have any resources
        random_user_id = str(uuid.uuid4())
        
        recent_uploads = Resources.get_recent_uploads_by_user(
            user_id=random_user_id,
            limit=10
        )
        
        assert isinstance(recent_uploads, list), "Result should be a list"
        assert len(recent_uploads) == 0, "Should return empty list for user with no resources"
    
    def test_get_recent_uploads_by_user_type_hints(self):
        """Test that the method has proper type hints."""
        import inspect
        
        # Get the method
        method = Resources.get_recent_uploads_by_user
        
        # Check that it's callable
        assert callable(method), "Should be callable"
        
        # Get the function signature
        sig = inspect.signature(method)
        
        # Check parameters
        params = sig.parameters
        assert 'user_id' in params, "Should have user_id parameter"
        assert 'limit' in params, "Should have limit parameter"
        
        # Check that limit has a default value
        assert params['limit'].default == 10, "Limit should default to 10"
        
        # Check return type annotation
        assert sig.return_annotation == typing.List[typing.Dict[str, typing.Any]], \
            "Should return List[Dict[str, Any]]"