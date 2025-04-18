"""
Test repository pattern with DuckDBService
"""

import pytest
import os
import tempfile
import uuid
from pydantic import BaseModel, Field
import typing

from percolate.models import repository, AbstractModel


class TestRepositoryEntity(BaseModel):
    """Test entity for repository pattern testing"""
    model_config = {'namespace': 'repo_test'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4, description="Entity unique identifier")
    name: str = Field(description="Entity name")
    value: int = Field(description="Numeric value")
    metadata: typing.Optional[dict] = Field(default_factory=dict, description="Additional metadata")


@pytest.fixture
def temp_dir():
    """Create temporary directory for test database"""
    with tempfile.TemporaryDirectory() as tmp_dir:
        yield tmp_dir


def test_repository_creation():
    """Test that repository factory function works"""
    try:
        # This will use either PostgresService or DuckDBService
        repo = repository(TestRepositoryEntity)
        assert repo is not None
        assert repo.model == AbstractModel.Abstracted(TestRepositoryEntity)
    except ImportError:
        pytest.skip("No database service available")


@pytest.fixture
def duck_db_path(temp_dir):
    """Get path for DuckDB database"""
    return os.path.join(temp_dir, "test_repo.db")


@pytest.fixture
def setup_duck_db(duck_db_path):
    """Setup DuckDB for repository tests"""
    try:
        from percolate.services.embedded import DuckDBService
        # Set environment variable to use DuckDB instead of PostgreSQL
        os.environ["PERCOLATE_USE_EMBEDDED"] = "true"
        os.environ["PERCOLATE_DB_PATH"] = duck_db_path
        yield
        # Clean up
        del os.environ["PERCOLATE_USE_EMBEDDED"]
        del os.environ["PERCOLATE_DB_PATH"]
    except ImportError:
        pytest.skip("DuckDB not available")


def test_duck_db_repository(setup_duck_db):
    """Test repository with DuckDB"""
    try:
        # Force use of DuckDBService directly instead of repository()
        from percolate.services.embedded import DuckDBService
        
        # Create repository
        repo = DuckDBService(TestRepositoryEntity)
        
        # Register entity
        repo.register()
        
        # Check if entity exists
        assert repo.entity_exists is True
        
        # Create and save entity with unique name
        import uuid
        unique_name = f"Repository Test Entity {uuid.uuid4()}"
        entity = TestRepositoryEntity(
            name=unique_name,
            value=42,
            metadata={"source": "test"}
        )
        repo.update_records(entity)
        
        # Query entity by unique name
        results = repo.select(name=unique_name)
        assert len(results) == 1
        assert results[0]['value'] == 42
        
    except ImportError:
        pytest.skip("DuckDB not available")