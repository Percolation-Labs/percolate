"""
Integration test for DuckDBService with embeddings and semantic search.
"""

import pytest
import os
import tempfile
import uuid
from pathlib import Path
import json

from percolate.models import AbstractModel
from percolate.utils import make_uuid
from percolate.services.embedded import DuckDBService
from pydantic import BaseModel, Field
import typing

class TestAgent(BaseModel):
    """Test agent entity for embedded database testing"""
    model_config = {'namespace': 'test'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4, description="Agent ID")
    name: str = Field(description="Agent name")
    description: str = Field(description="Agent description", json_schema_extra={'embedding_provider': 'default'})
    category: str = Field(description="Agent category")
    capabilities: typing.List[str] = Field(default_factory=list, description="Agent capabilities")

@pytest.fixture
def temp_db_path():
    """Create a temporary database path for testing."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test.db")
        yield db_path

@pytest.fixture
def agent_repo(temp_db_path):
    """Create a repository for the TestAgent model."""
    service = DuckDBService(TestAgent, db_path=temp_db_path)
    service.register()
    yield service
    
def test_basic_crud_and_upsert(agent_repo):
    """Test basic CRUD operations and upsert functionality."""
    # Create agents with deterministic IDs
    agents = [
        TestAgent(
            id=make_uuid("SearchAgent"),  # Generate ID from name for deterministic lookups
            name="SearchAgent",
            category="Research",
            description="Agent that performs web searches",
            capabilities=["search", "summarize"]
        ),
        TestAgent(
            id=make_uuid("WriterAgent"),  # Generate ID from name for deterministic lookups
            name="WriterAgent",
            category="Content",
            description="Agent that writes content based on prompts",
            capabilities=["write", "edit"]
        )
    ]
    
    # Insert agents
    agent_repo.update_records(agents)
    
    # Verify they were inserted
    search_agent = agent_repo.select(id=make_uuid("SearchAgent"))
    assert len(search_agent) == 1
    assert search_agent[0]['name'] == "SearchAgent"
    
    # Update an existing agent (upsert)
    updated_agent = TestAgent(
        id=make_uuid("WriterAgent"),  # Same ID as before
        name="WriterAgent",
        category="Content Creation",  # Changed category
        description="Agent that writes and edits high-quality content",  # Changed description
        capabilities=["write", "edit", "format"]  # Added capability
    )
    
    agent_repo.update_records(updated_agent)
    
    # Verify the update
    writer_agent = agent_repo.select(id=make_uuid("WriterAgent"))
    assert len(writer_agent) == 1
    assert writer_agent[0]['category'] == "Content Creation"
    assert "Agent that writes and edits high-quality content" in writer_agent[0]['description']
    
    # Verify we still have only 2 agents (no duplicates)
    all_agents = agent_repo.execute("SELECT COUNT(*) as count FROM test_testagent")
    assert all_agents[0]['count'] == 2

def test_embeddings_and_search(agent_repo):
    """Test embedding generation and semantic search."""
    # Create test agents
    agents = [
        TestAgent(
            id=make_uuid("SearchAgent"),
            name="SearchAgent",
            description="Agent that performs comprehensive web searches and summarizes results",
            category="Research",
            capabilities=["search", "summarize"]
        ),
        TestAgent(
            id=make_uuid("CodeAgent"),
            name="CodeAgent",
            description="Agent that generates and reviews code in multiple programming languages",
            category="Development",
            capabilities=["code", "review"]
        ),
        TestAgent(
            id=make_uuid("WriterAgent"),
            name="WriterAgent",
            description="Agent that writes and edits high-quality content based on prompts",
            category="Content",
            capabilities=["write", "edit"]
        )
    ]
    
    # Insert agents
    agent_repo.update_records(agents)
    
    # Prepare records for embeddings
    records = [
        {"id": str(make_uuid("SearchAgent")), "description": "Agent that performs comprehensive web searches and summarizes results"},
        {"id": str(make_uuid("CodeAgent")), "description": "Agent that generates and reviews code in multiple programming languages"},
        {"id": str(make_uuid("WriterAgent")), "description": "Agent that writes and edits high-quality content based on prompts"}
    ]
    
    # Add embeddings
    embedding_result = agent_repo.add_embeddings(records, embedding_field="description")
    assert embedding_result["success"] is True
    assert embedding_result["embeddings_added"] == 3
    
    # Check embedding table - use the standard table name from the EmbeddingRecord model
    from percolate.models.p8.embedding_types import EmbeddingRecord
    embedding_namespace = EmbeddingRecord.model_config.get('namespace', 'common').lower()
    embedding_name = EmbeddingRecord.model_config.get('table_name', 'embeddingrecord').lower()
    
    # Determine embedding table name
    if embedding_namespace.lower() == "test":
        embedding_table = f"{embedding_namespace}_{embedding_name}"
    else:
        embedding_table = f"{embedding_namespace}.{embedding_name}"
        
    embeddings = agent_repo.execute(f"SELECT * FROM {embedding_table}")
    assert len(embeddings) == 3
    
    # Test semantic search
    code_results = agent_repo.semantic_search("programming code", limit=1)
    assert len(code_results) == 1
    assert "Code" in code_results[0]["name"]
    
    writing_results = agent_repo.semantic_search("writing content", limit=1)
    assert len(writing_results) == 1
    assert "Writer" in writing_results[0]["name"]

def test_finding_agents_by_capabilities(agent_repo):
    """Test finding agents by capabilities in JSON fields."""
    # Create test agents with different capabilities
    agents = [
        TestAgent(
            id=make_uuid("SearchAgent"),
            name="SearchAgent",
            description="Search agent",
            category="Research",
            capabilities=["search", "summarize"]
        ),
        TestAgent(
            id=make_uuid("WriterAgent"),
            name="WriterAgent",
            description="Writer agent",
            category="Content",
            capabilities=["write", "edit", "proofread"]
        ),
        TestAgent(
            id=make_uuid("AnalysisAgent"),
            name="AnalysisAgent",
            description="Analysis agent",
            category="Analytics",
            capabilities=["analyze", "visualize"]
        )
    ]
    
    # Insert agents
    agent_repo.update_records(agents)
    
    # Find agents with edit capability
    query = """
    SELECT name FROM test_testagent 
    WHERE capabilities::TEXT LIKE '%edit%'
    """
    edit_agents = agent_repo.execute(query)
    assert len(edit_agents) == 1
    assert edit_agents[0]["name"] == "WriterAgent"
    
    # Find agents with search capability
    query = """
    SELECT name FROM test_testagent 
    WHERE capabilities::TEXT LIKE '%search%'
    """
    search_agents = agent_repo.execute(query)
    assert len(search_agents) == 1
    assert search_agents[0]["name"] == "SearchAgent"

def main():
    """Run tests manually for demonstration."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test.db")
        agent_repo = DuckDBService(TestAgent, db_path=db_path)
        agent_repo.register()
        
        print("Running basic CRUD and upsert test...")
        test_basic_crud_and_upsert(agent_repo)
        print("✅ Basic CRUD and upsert test passed")
        
        print("Running embeddings and search test...")
        test_embeddings_and_search(agent_repo)
        print("✅ Embeddings and search test passed")
        
        print("Running capabilities search test...")
        test_finding_agents_by_capabilities(agent_repo)
        print("✅ Capabilities search test passed")
        
        print("All tests passed successfully!")

if __name__ == "__main__":
    main()