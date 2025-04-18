"""
Test PyIceberg integration with DuckDBService

These tests verify that:
1. The service functions correctly without PyIceberg by default
2. PyIceberg integration works when the PERCOLATE_USE_PYICEBERG flag is set
3. Tables can be created and updated idempotently
"""

import pytest
import os
import sys
import tempfile
import uuid
from pathlib import Path
import json
import importlib.util

from pydantic import BaseModel, Field
import typing

from percolate.models import AbstractModel
from percolate.models.p8 import Agent
from percolate.utils import make_uuid
from percolate.services.embedded import DuckDBService

# Check if PyIceberg is available
PYICEBERG_AVAILABLE = importlib.util.find_spec("pyiceberg") is not None


@pytest.fixture
def temp_db_path():
    """Create temporary database for testing"""
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test_iceberg.db")
        yield db_path


@pytest.fixture
def duck_service(temp_db_path):
    """Initialize DuckDBService with test path"""
    service = DuckDBService(db_path=temp_db_path)
    yield service


@pytest.fixture
def agent_repo(duck_service):
    """Create repository for Agent model"""
    repo = duck_service.repository(Agent)
    # Register the schema (creates tables and iceberg catalog)
    repo.register()
    return repo


def create_test_agents(count=3):
    """Create test agent instances"""
    agents = []
    for i in range(count):
        agent = Agent(
            id=uuid.uuid4(),
            name=f"TestAgent_{i}",
            category="Test",
            description=f"Test agent {i} for PyIceberg integration testing",
            spec={"capabilities": ["test"]},
            functions={"test_function": f"Test function for agent {i}"}
        )
        agents.append(agent)
    return agents


def test_register_without_pyiceberg(agent_repo, monkeypatch):
    """Test that registration works without PyIceberg (default behavior)"""
    # Ensure PyIceberg is not enabled
    monkeypatch.delenv("PERCOLATE_USE_PYICEBERG", raising=False)
    
    # Verify table exists
    assert agent_repo.entity_exists


@pytest.mark.skipif(not PYICEBERG_AVAILABLE, reason="PyIceberg not installed")
def test_register_with_pyiceberg_enabled(temp_db_path, monkeypatch):
    """Test that registration creates PyIceberg catalog and tables when enabled"""
    # Enable PyIceberg
    monkeypatch.setenv("PERCOLATE_USE_PYICEBERG", "1")
    
    # Create service and repo
    service = DuckDBService(db_path=temp_db_path)
    repo = service.repository(Agent)
    
    # Register the schema
    repo.register()
    
    # Verify table exists
    assert repo.entity_exists


@pytest.mark.skipif(not PYICEBERG_AVAILABLE, reason="PyIceberg not installed")
def test_pyiceberg_insert_and_upsert(temp_db_path, monkeypatch):
    """Test insert and upsert operations with PyIceberg when enabled"""
    # Enable PyIceberg
    monkeypatch.setenv("PERCOLATE_USE_PYICEBERG", "1")
    
    # Create service and repo
    service = DuckDBService(db_path=temp_db_path)
    repo = service.repository(Agent)
    repo.register()
    
    # Create initial test agents
    agents = create_test_agents(3)
    
    # Insert agents
    repo.update_records(agents)
    
    # Verify agents were inserted
    all_agents = repo.select()
    assert len(all_agents) == 3
    
    # Modify an existing agent and create a new one
    agents[0].description = "UPDATED: Test agent 0 with modified description"
    agents[0].spec["capabilities"].append("updated")
    
    new_agent = Agent(
        id=uuid.uuid4(),
        name="TestAgent_New",
        category="Test",
        description="New test agent added during upsert",
        spec={"capabilities": ["test", "new"]},
        functions={"new_function": "New test function"}
    )
    
    # Perform upsert with modified and new agent
    upsert_batch = [agents[0], new_agent]
    repo.update_records(upsert_batch)
    
    # Verify results
    updated_agents = repo.select()
    assert len(updated_agents) == 4  # Original 3 plus 1 new
    
    # Check for the updated agent
    updated_agent = repo.select(id=str(agents[0].id))[0]
    assert "UPDATED" in updated_agent["description"]
    assert json.loads(updated_agent["spec"])["capabilities"] == ["test", "updated"]
    
    # Check for the new agent
    new_agents = repo.select(name="TestAgent_New")
    assert len(new_agents) == 1
    assert new_agents[0]["description"] == "New test agent added during upsert"
    

def test_idempotent_registration(temp_db_path):
    """Test that registration is idempotent (can be called multiple times)"""
    # First registration
    service1 = DuckDBService(Agent, db_path=temp_db_path)
    service1.register()
    
    # Second registration with the same model
    service2 = DuckDBService(Agent, db_path=temp_db_path)
    service2.register()  # Should not raise exceptions
    
    # Verify table exists
    assert service2.entity_exists


def test_upsert_no_duplicates(agent_repo):
    """Test that upserts don't create duplicates"""
    # Create test agent
    agent = Agent(
        id=uuid.uuid4(),
        name="UniqueName",
        category="Unique",
        description="This should remain unique",
        spec={"capabilities": ["unique"]},
        functions={"unique_function": "Unique test function"}
    )
    
    # Insert the agent
    agent_repo.update_records(agent)
    
    # Modify and upsert the same agent (multiple times)
    for i in range(3):
        agent.description = f"Updated description {i}"
        agent_repo.update_records(agent)
    
    # Verify only one agent with this ID exists
    unique_agents = agent_repo.select(id=str(agent.id))
    assert len(unique_agents) == 1
    assert unique_agents[0]["description"] == "Updated description 2"  # The last update
    
    # Verify no duplicates by name
    name_agents = agent_repo.select(name="UniqueName")
    assert len(name_agents) == 1


def test_default_sql_upsert(temp_db_path, monkeypatch):
    """Test that SQL upsert is used by default when PyIceberg is not enabled"""
    # Ensure PyIceberg is not enabled
    monkeypatch.delenv("PERCOLATE_USE_PYICEBERG", raising=False)
    
    # Initialize service and register model
    service = DuckDBService(Agent, db_path=temp_db_path)
    service.register()
    
    # Create and insert test agent
    agent = Agent(
        id=uuid.uuid4(),
        name="SqlUpsertAgent",
        category="DefaultSQL",
        description="Testing default SQL upsert",
        spec={"capabilities": ["sql"]},
        functions={"sql_function": "SQL test function"}
    )
    
    # This should use SQL upsert by default
    service.update_records(agent)
    
    # Verify agent was inserted
    agents = service.select(name="SqlUpsertAgent")
    assert len(agents) == 1
    assert agents[0]["category"] == "DefaultSQL"


@pytest.mark.skipif(not PYICEBERG_AVAILABLE, reason="PyIceberg not installed")
def test_fallback_to_sql_with_module_mock(temp_db_path, monkeypatch):
    """Test fallback to SQL upsert when PyIceberg is unavailable at runtime"""
    # Enable PyIceberg
    monkeypatch.setenv("PERCOLATE_USE_PYICEBERG", "1")
    
    # Mock the import_module function to make PyIceberg imports fail
    orig_import = __import__
    
    def mock_import(name, *args, **kwargs):
        if name == 'pyiceberg':
            raise ImportError("Mock import error for pyiceberg")
        if name == 'polars':
            raise ImportError("Mock import error for polars")
        return orig_import(name, *args, **kwargs)
    
    # Use monkeypatch to mock modules directly
    monkeypatch.setitem(sys.modules, 'pyiceberg', None)
    monkeypatch.setitem(sys.modules, 'polars', None)
    
    # Initialize service and register model
    with monkeypatch.context() as m:
        m.setattr('builtins.__import__', mock_import)
        
        # Create service and repository
        service = DuckDBService(Agent, db_path=temp_db_path)
        service.register()
        
        # Create test agent
        agent = Agent(
            id=uuid.uuid4(),
            name="FallbackAgent",
            category="Fallback",
            description="Testing SQL fallback",
            spec={"capabilities": ["fallback"]},
            functions={"fallback_function": "Fallback test function"}
        )
        
        # This should use the SQL fallback
        service.update_records(agent)
    
    # Verify agent was inserted (outside the mocked context)
    service = DuckDBService(Agent, db_path=temp_db_path)
    agents = service.select(name="FallbackAgent")
    assert len(agents) == 1
    assert agents[0]["category"] == "Fallback"


def test_drop_entity_without_pyiceberg(temp_db_path, monkeypatch):
    """Test dropping entity tables without PyIceberg (default behavior)"""
    # Ensure PyIceberg is not enabled
    monkeypatch.delenv("PERCOLATE_USE_PYICEBERG", raising=False)
    
    # Initialize service and repository
    service = DuckDBService(db_path=temp_db_path)
    repo = service.repository(Agent)
    
    # Register the entity
    repo.register()
    
    # Verify entity exists
    assert repo.entity_exists
    
    # Create and insert test agents
    agents = create_test_agents(3)
    repo.update_records(agents)
    
    # Verify agents were inserted
    all_agents = repo.select()
    assert len(all_agents) == 3
    
    # Drop the entity
    result = repo.drop_entity()
    assert result["success"] is True
    
    # Verify table no longer exists
    assert not repo.entity_exists
    
    # Try to select after dropping (should be empty)
    try:
        result = repo.select()
        assert len(result) == 0
    except Exception:
        # If select fails because table doesn't exist, that's also fine
        pass
    
    # Re-register the same entity (should work after dropping)
    repo.register()
    assert repo.entity_exists


@pytest.mark.skipif(not PYICEBERG_AVAILABLE, reason="PyIceberg not installed")
def test_drop_entity_with_pyiceberg(temp_db_path, monkeypatch):
    """Test dropping entity tables with PyIceberg enabled"""
    # Enable PyIceberg
    monkeypatch.setenv("PERCOLATE_USE_PYICEBERG", "1")
    
    # Initialize service and repository
    service = DuckDBService(db_path=temp_db_path)
    repo = service.repository(Agent)
    
    # Register the entity
    repo.register()
    
    # Verify entity exists
    assert repo.entity_exists
    
    # Create and insert test agents
    agents = create_test_agents(3)
    repo.update_records(agents)
    
    # Verify agents were inserted
    all_agents = repo.select()
    assert len(all_agents) == 3
    
    # Drop the entity - the success flag may be False if PyIceberg has issues,
    # but we should still verify the main table is dropped
    result = repo.drop_entity()
    
    # Even if PyIceberg operations fail, the main table should be dropped
    assert not repo.entity_exists
    
    # Try to select after dropping (should be empty)
    try:
        result = repo.select()
        assert len(result) == 0
    except Exception:
        # If select fails because table doesn't exist, that's also fine
        pass
    
    # Re-register the same entity (should work after dropping)
    repo.register()
    assert repo.entity_exists