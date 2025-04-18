"""
Test DuckDBService for Embedded Percolate
"""

import pytest
import os
import tempfile
import uuid
from pathlib import Path
from pydantic import BaseModel, Field
import typing

from percolate.models import AbstractModel
from percolate.utils import make_uuid
from percolate.services.embedded import DuckDBService


class TestEntity(BaseModel):
    """Test entity for DuckDB testing"""
    model_config = {'namespace': 'test'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4, description="Entity unique identifier")
    name: str = Field(description="Entity name")
    description: str = Field(description="Entity description", json_schema_extra={'embedding_provider': 'default'})
    metadata: typing.Optional[dict] = Field(default_factory=dict, description="Additional metadata")


@pytest.fixture
def duck_db_path():
    """Create temporary database for testing"""
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test.db")
        yield db_path


@pytest.fixture
def duck_db_service(duck_db_path):
    """Initialize DuckDBService with test path"""
    service = DuckDBService(db_path=duck_db_path)
    yield service


@pytest.fixture
def test_entity_repository(duck_db_service):
    """Create repository for TestEntity"""
    repo = duck_db_service.repository(TestEntity)
    return repo


def test_service_initialization(duck_db_service):
    """Test that service initializes correctly"""
    assert duck_db_service is not None
    assert duck_db_service.conn is not None
    assert duck_db_service.helper is not None


def test_register_entity(test_entity_repository):
    """Test entity registration creates tables"""
    # Register the entity
    result = test_entity_repository.register(plan=False, register_entities=True)
    
    # Create a test entity to verify tables are accessible
    entity = TestEntity(
        id=uuid.uuid4(),
        name="Registration Test",
        description="Test for table registration",
        metadata={"test": "registration"}
    )
    
    # Try to insert the entity
    test_entity_repository.update_records(entity)
    
    # Try to query the entity
    # If tables are accessible this should work regardless of entity_exists check
    query_result = test_entity_repository.select(name="Registration Test")
    assert len(query_result) > 0
    
    # Check if embedding table exists in principle
    assert test_entity_repository.helper.table_has_embeddings is True


def test_create_and_retrieve_entity(test_entity_repository):
    """Test creating and retrieving entities"""
    # Register the entity type
    test_entity_repository.register()
    
    # Create test entity with deterministic ID from name
    name = "Test Entity"
    test_id = make_uuid(name)
    entity = TestEntity(
        id=test_id,
        name=name,
        description="This is a test entity description",
        metadata={"key": "value"}
    )
    
    # Insert the entity
    test_entity_repository.update_records(entity)
    
    # Retrieve the entity
    retrieved = test_entity_repository.select(id=test_id)
    
    # Verify retrieval
    assert len(retrieved) == 1
    assert str(retrieved[0]['id']) == str(test_id)
    assert retrieved[0]['name'] == name
    assert retrieved[0]['description'] == "This is a test entity description"


def test_batch_insert(test_entity_repository):
    """Test batch insertion of entities"""
    # Register the entity type
    test_entity_repository.register()
    
    # Create multiple test entities
    entities = []
    for i in range(10):
        # Use hash of name as ID for deterministic IDs
        name = f"Test Entity {i}"
        entity_id = make_uuid(name)
        entities.append(TestEntity(
            id=entity_id,
            name=name,
            description=f"Description for entity {i}",
            metadata={"index": i}
        ))
    
    # Insert entities in batch
    test_entity_repository.update_records(entities, batch_size=5, index_entities=False)
    
    # Verify all entities were inserted
    all_entities = test_entity_repository.select()
    assert len(all_entities) == 10


def test_entity_upsert(test_entity_repository):
    """Test upsert functionality with same ID"""
    # Register the entity type
    test_entity_repository.register()
    
    # Create initial entity with deterministic ID from name
    name = "Upsert Test Entity"
    entity_id = make_uuid(name)
    
    entity1 = TestEntity(
        id=entity_id,
        name=name,
        description="Initial description",
        metadata={"version": 1}
    )
    
    # Insert the first entity
    test_entity_repository.update_records(entity1)
    
    # Create second entity with same ID but updated fields
    entity2 = TestEntity(
        id=entity_id,  # Same ID as before
        name=name,     # Same name
        description="Updated description",  # Changed
        metadata={"version": 2}  # Changed
    )
    
    # Update with second entity
    test_entity_repository.update_records(entity2)
    
    # Retrieve the entity
    results = test_entity_repository.select(id=entity_id)
    
    # Verify only one entity exists and it has updated values
    assert len(results) == 1
    assert results[0]['name'] == name
    assert results[0]['description'] == "Updated description"
    # DuckDB returns metadata as a JSON string, so we need to check it differently
    import json
    metadata = json.loads(results[0]['metadata'])
    assert metadata.get('version') == 2


def test_entity_search(test_entity_repository):
    """Test entity search with filtering"""
    # Register the entity type
    test_entity_repository.register()
    
    # Create test entity with deterministic ID
    name = "Special Entity"
    entity_id = make_uuid(name)
    
    entity = TestEntity(
        id=entity_id,
        name=name,
        description="This entity has a unique description",
        metadata={"type": "special"}
    )
    
    # Insert the entity
    test_entity_repository.update_records(entity)
    
    # Search by name
    results = test_entity_repository.select(name="Special Entity")
    assert len(results) == 1
    assert results[0]['name'] == "Special Entity"