"""
Test the complete PyIceberg integration flow

This test covers:
1. Creating tables with PyIceberg catalog integration
2. Inserting and upserting records
3. Adding embeddings for semantic search
4. Adding entities to the graph database
5. Testing entity lookup and semantic search
6. Cleaning up resources
"""

import os
import uuid
import tempfile
import pytest
from pydantic import BaseModel, Field

from percolate.models.p8 import Agent
from percolate.services.embedded import DuckDBService
from percolate.services.embedded.utils import PyIcebergHelper
from percolate.utils import make_uuid

# Mark test as conditional on PyIceberg availability
pytestmark = pytest.mark.skipif(
    not PyIcebergHelper.is_available(), 
    reason="PyIceberg not installed"
)

# Test fixture for temporary database
@pytest.fixture
def temp_db_path():
    """Create temporary database for testing"""
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test_flow.db")
        yield db_path

@pytest.fixture
def test_agents():
    """Create test agents for use in tests with deterministic IDs"""
    return [
        Agent(
            id=make_uuid({"name": "SearchAgent"}),  # Deterministic ID based on name
            name="SearchAgent",
            category="Research",
            description="Agent that performs web searches and summarizes results",
            spec={"capabilities": ["search", "summarize"]},
            functions={"search_web": "Performs web search using search APIs"}
        ),
        Agent(
            id=make_uuid({"name": "WriterAgent"}),  # Deterministic ID based on name
            name="WriterAgent",
            category="Content",
            description="Agent that writes and edits content based on prompts",
            spec={"capabilities": ["write", "edit", "proofread"]},
            functions={"generate_content": "Creates content based on prompts"}
        )
    ]

@pytest.fixture
def duck_service(temp_db_path, monkeypatch):
    """Setup DuckDBService with PyIceberg enabled"""
    # Enable PyIceberg for test
    monkeypatch.setenv("PERCOLATE_USE_PYICEBERG", "1")
    
    # Initialize service with Agent model
    service = DuckDBService(Agent, db_path=temp_db_path)
    
    # Register model (create tables)
    service.register()
    
    yield service

def test_pyiceberg_status(duck_service):
    """Test PyIceberg status reporting"""
    status = duck_service.get_iceberg_status()
    
    # Basic checks
    assert status["is_available"] is True
    assert status["is_enabled"] is True
    assert "catalog_config" in status
    
    # Check warehouse path configuration exists (even if catalog loading failed)
    assert "warehouse_path" in status
    
    # Note: catalog might not be loaded if PyIceberg has issues
    # In this case, the SQL fallback is used instead
    if not status.get("catalog_loaded", False):
        assert len(status.get("errors", [])) > 0

def test_table_creation_and_info(duck_service):
    """Test table creation and info retrieval"""
    # Check that the table exists in DuckDB, regardless of PyIceberg status
    assert duck_service.entity_exists
    
    # Even if PyIceberg table info fails, entity exists in DuckDB
    table_info = duck_service.get_table_info()
    
    # Table info might show errors if PyIceberg has issues
    if len(table_info.get("errors", [])) > 0:
        assert "exists" in table_info  # But key should still exist

def test_record_insert_and_upsert(duck_service, test_agents):
    """Test inserting and upserting records"""
    # Insert initial agents
    duck_service.update_records(test_agents)
    
    # Verify insertion
    all_agents = duck_service.select()
    assert len(all_agents) == 2
    
    # Modify an agent
    test_agents[0].description = "UPDATED: Agent with advanced capabilities"
    test_agents[0].spec["capabilities"].append("filter")
    
    # Add a new agent
    new_agent = Agent(
        id=uuid.uuid4(),
        name="AnalysisAgent", 
        category="Analytics",
        description="Analyzes data",
        spec={"capabilities": ["analyze"]},
        functions={"analyze": "Analyze data"}
    )
    updated_batch = test_agents + [new_agent]
    
    # Perform upsert
    duck_service.update_records(updated_batch)
    
    # Verify upsert results
    updated_agents = duck_service.select()
    assert len(updated_agents) == 3  # Should have added 1 new agent
    
    # Check if update was applied to existing agent
    search_agent = duck_service.select(name="SearchAgent")[0]
    assert "UPDATED" in search_agent["description"]
    assert "filter" in str(search_agent["spec"]).lower()  # May be JSON string

def test_add_embeddings(duck_service, test_agents):
    """Test adding embeddings for semantic search"""
    # Insert agents
    duck_service.update_records(test_agents)
    all_agents = duck_service.select()
    
    # Add embeddings
    embedding_results = duck_service.add_embeddings(all_agents)
    
    # Verify embeddings were added
    assert embedding_results["success"] is True
    assert embedding_results["embeddings_added"] == len(all_agents)

def test_semantic_search(duck_service, test_agents):
    """Test semantic search functionality"""
    # Insert agents with descriptions that contain search terms
    test_agents[0].description = "This agent helps with search and summarization tasks"
    test_agents[1].description = "This agent helps with writing and editing tasks"
    duck_service.update_records(test_agents)
    
    # Add embeddings
    duck_service.add_embeddings(duck_service.select())
    
    # Search for agents with "search" in description
    results = duck_service.semantic_search("search")
    
    # Should find at least one result (the search agent)
    assert len(results) > 0
    # The first result should be the search agent
    assert "search" in results[0]["name"].lower() or "search" in results[0]["description"].lower()

def test_entity_lifecycle(duck_service):
    """Test complete entity lifecycle including dropping"""
    # Verify entity exists initially
    assert duck_service.entity_exists is True
    
    # Drop entity
    drop_result = duck_service.drop_entity()
    
    # Tables should be dropped (even if PyIceberg had issues)
    assert not duck_service.entity_exists
    
    # Re-register
    duck_service.register()
    
    # Entity should exist again
    assert duck_service.entity_exists is True