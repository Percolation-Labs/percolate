"""
Integration tests for Embedded Percolate services
"""

import pytest
import os
import tempfile
import uuid
import asyncio
from pydantic import BaseModel, Field
import typing

from percolate.models import AbstractModel
from percolate.services.embedded import DuckDBService, KuzuDBService
from percolate.services.embedded.utils import run_async


class TestEntity(BaseModel):
    """Test entity for integration testing"""
    model_config = {'namespace': 'integration'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4, description="Entity unique identifier")
    name: str = Field(description="Entity name")
    description: str = Field(description="Entity description", json_schema_extra={'embedding_provider': 'default'})
    category: str = Field(description="Entity category")
    metadata: typing.Optional[dict] = Field(default_factory=dict, description="Additional metadata")


@pytest.fixture
def temp_dir():
    """Create temporary directory for test databases"""
    with tempfile.TemporaryDirectory() as tmp_dir:
        yield tmp_dir


@pytest.fixture
def duck_db_service(temp_dir):
    """Initialize DuckDBService with test path"""
    db_path = os.path.join(temp_dir, "test.db")
    service = DuckDBService(db_path=db_path)
    yield service


@pytest.fixture
def kuzu_db_service(temp_dir):
    """Initialize KuzuDBService with test path"""
    try:
        db_path = os.path.join(temp_dir, "test_graph")
        service = KuzuDBService(db_path=db_path)
        if service.conn is None:
            pytest.skip("KuzuDB not available - skipping tests")
        yield service
    except ImportError:
        pytest.skip("KuzuDB not installed - skipping tests")


@pytest.fixture
def test_entity_repository(duck_db_service):
    """Create repository for TestEntity"""
    repo = duck_db_service.repository(TestEntity)
    repo.register(register_entities=True)
    return repo


@pytest.mark.slow
def test_end_to_end_workflow(test_entity_repository, kuzu_db_service):
    """Test complete workflow from creation to search"""
    # Create test entities with different categories
    entities = []
    for i in range(10):
        category = "primary" if i < 5 else "secondary"
        entities.append(TestEntity(
            id=uuid.uuid4(),
            name=f"Integration Entity {i}",
            description=f"Description for integration entity {i}",
            category=category,
            metadata={"index": i}
        ))
    
    # Insert entities with index building
    test_entity_repository.update_records(entities, index_entities=True)
    
    # Verify SQL storage
    all_entities = test_entity_repository.select()
    assert len(all_entities) == 10
    
    # Filter by category
    primary_entities = test_entity_repository.select(category="primary")
    assert len(primary_entities) == 5
    
    # Verify graph storage (this might be skipped if KuzuDB is not available)
    if kuzu_db_service.conn is not None:
        # Entity nodes should have been created through index_entities
        for entity in entities:
            result = kuzu_db_service.get_entity_by_id(str(entity.id))
            assert result is not None
            assert result["name"] == entity.name


@pytest.mark.asyncio
async def test_async_index_building(test_entity_repository):
    """Test that indexes are built asynchronously"""
    # Create test entity
    entity = TestEntity(
        id=uuid.uuid4(),
        name="Async Test Entity",
        description="Testing async index building",
        category="test",
        metadata={"async": True}
    )
    
    # Insert without indexing
    test_entity_repository.update_records(entity, index_entities=False)
    
    # Manually trigger async index building
    metrics = await test_entity_repository.build_indexes(
        entity_name=TestEntity.model_config['namespace'] + "." + TestEntity.__name__
    )
    
    # Verify metrics
    assert "entities_added" in metrics
    assert "embeddings_added" in metrics