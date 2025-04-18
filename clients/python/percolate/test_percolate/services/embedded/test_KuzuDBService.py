"""
Test KuzuDBService for Embedded Percolate
"""

import pytest
import os
import tempfile
import uuid
from pathlib import Path

from percolate.services.embedded import KuzuDBService


@pytest.fixture
def kuzu_db_path():
    """Create temporary database for testing"""
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test_graph")
        yield db_path


@pytest.fixture
def kuzu_service(kuzu_db_path):
    """Initialize KuzuDBService with test path"""
    try:
        service = KuzuDBService(db_path=kuzu_db_path)
        if service.conn is None:
            pytest.skip("KuzuDB not available - skipping tests")
        yield service
    except ImportError:
        pytest.skip("KuzuDB not installed - skipping tests")


def test_service_initialization(kuzu_service):
    """Test that service initializes correctly"""
    assert kuzu_service is not None
    assert kuzu_service.conn is not None


def test_register_entity_type(kuzu_service):
    """Test entity type registration"""
    result = kuzu_service.register_entity("test.TestEntity")
    assert result is True


def test_add_entities(kuzu_service):
    """Test adding entity nodes"""
    # Register entity type
    kuzu_service.register_entity("test.TestEntity")
    
    # Create test entities
    entities = [
        {"id": str(uuid.uuid4()), "name": "Entity 1"},
        {"id": str(uuid.uuid4()), "name": "Entity 2"},
        {"id": str(uuid.uuid4()), "name": "Entity 3"}
    ]
    
    # Add entities
    count = kuzu_service.add_entities("test.TestEntity", entities)
    assert count == 3


def test_get_entity_by_name(kuzu_service):
    """Test retrieving entities by name"""
    # Register entity type
    kuzu_service.register_entity("test.TestEntity")
    
    # Create and add a test entity
    entity_id = str(uuid.uuid4())
    entities = [{"id": entity_id, "name": "Unique Entity Name"}]
    kuzu_service.add_entities("test.TestEntity", entities)
    
    # Retrieve by name
    results = kuzu_service.get_entity_by_name("Unique Entity")
    assert len(results) == 1
    assert results[0]["id"] == entity_id
    assert results[0]["name"] == "Unique Entity Name"
    assert results[0]["type"] == "test.TestEntity"


def test_get_entity_by_id(kuzu_service):
    """Test retrieving entity by ID"""
    # Register entity type
    kuzu_service.register_entity("test.TestEntity")
    
    # Create and add a test entity
    entity_id = str(uuid.uuid4())
    entities = [{"id": entity_id, "name": "Test Entity"}]
    kuzu_service.add_entities("test.TestEntity", entities)
    
    # Retrieve by ID
    result = kuzu_service.get_entity_by_id(entity_id)
    assert result is not None
    assert result["id"] == entity_id
    assert result["name"] == "Test Entity"
    assert result["type"] == "test.TestEntity"


def test_create_relationship(kuzu_service):
    """Test creating relationships between entities"""
    # Register entity type
    kuzu_service.register_entity("test.TestEntity")
    
    # Create and add two test entities
    entity1_id = str(uuid.uuid4())
    entity2_id = str(uuid.uuid4())
    entities = [
        {"id": entity1_id, "name": "Entity 1"},
        {"id": entity2_id, "name": "Entity 2"}
    ]
    kuzu_service.add_entities("test.TestEntity", entities)
    
    # Create relationship
    result = kuzu_service.create_relationship(
        entity1_id, entity2_id, "RELATED_TO", weight=0.75
    )
    assert result is True
    
    # Verify relationship with Cypher query
    query = """
    MATCH (a:Entity {id: $id1})-[r:Relationship]->(b:Entity {id: $id2})
    RETURN r.type as type, r.weight as weight
    """
    params = {"id1": entity1_id, "id2": entity2_id}
    results = kuzu_service.execute_cypher(query, params)
    
    assert len(results) == 1
    assert results[0]["type"] == "RELATED_TO"
    assert results[0]["weight"] == 0.75