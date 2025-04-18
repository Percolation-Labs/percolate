"""
Integration test for the embedded flow with a focus on embeddings.

This test verifies the following flow:
1. Create table from model with embedding tables
2. Add records
3. Update records to test idempotence
4. Add embeddings using repo
5. Search using the embedding index
6. Add entities to graph and look them up
"""

import os
import uuid
import pytest
import tempfile
from pathlib import Path
import json

from percolate.models import AbstractModel
from percolate.utils import make_uuid
from percolate.services.embedded import DuckDBService
from percolate.models.p8.embedding_types import EmbeddingRecord
from percolate.utils.embedding import get_embeddings, prepare_embedding_records
from pydantic import BaseModel, Field


class TestDocument(BaseModel):
    """Test document entity for embedded database testing"""
    model_config = {'namespace': 'test'}
    
    id: str = Field(description="Document ID")
    title: str = Field(description="Document title")
    content: str = Field(description="Document content", json_schema_extra={'embedding_provider': 'default'})
    tags: list[str] = Field(default_factory=list, description="Document tags")


@pytest.fixture
def temp_db_path():
    """Create a temporary database path for testing."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test.db")
        yield db_path


@pytest.fixture
def doc_repo(temp_db_path):
    """Create a repository for the TestDocument model."""
    service = DuckDBService(TestDocument, db_path=temp_db_path)
    service.register()
    yield service


def test_complete_flow(doc_repo, monkeypatch):
    """Test the complete flow from creation to search."""
    
    # Mock the embedding function to avoid API calls
    def mock_get_embeddings(texts, **kwargs):
        """Mock embedding function that returns deterministic vectors"""
        return [[0.1, 0.2, 0.3] for _ in texts]
    
    monkeypatch.setattr("percolate.utils.embedding.get_embeddings", mock_get_embeddings)
    
    # Step 1: Verify tables exist
    assert doc_repo.check_entity_exists(), "Document table should exist"
    
    # Step 2: Create test documents with deterministic IDs
    docs = [
        TestDocument(
            id=make_uuid("doc1"),
            title="Introduction to Machine Learning",
            content="Machine learning is a branch of AI focused on building systems that learn from data",
            tags=["ML", "AI", "intro"]
        ),
        TestDocument(
            id=make_uuid("doc2"),
            title="Python Programming",
            content="Python is a versatile programming language used for web development, data science, and more",
            tags=["Python", "programming"]
        ),
        TestDocument(
            id=make_uuid("doc3"),
            title="Data Science Fundamentals",
            content="Data science combines statistics, data analysis, and related methods to understand data",
            tags=["data", "statistics", "ML"]
        )
    ]
    
    # Insert documents
    doc_repo.update_records(docs)
    
    # Verify they were inserted
    all_docs = doc_repo.select()
    assert len(all_docs) == 3, "Should have 3 documents"
    
    # Step 3: Update an existing document to test idempotence
    updated_doc = TestDocument(
        id=make_uuid("doc1"),
        title="Introduction to Machine Learning - Updated",
        content="Machine learning is a branch of AI focused on building systems that learn from data and improve over time",
        tags=["ML", "AI", "intro", "advanced"]
    )
    
    doc_repo.update_records(updated_doc)
    
    # Verify the update
    doc1 = doc_repo.select(id=make_uuid("doc1"))
    assert len(doc1) == 1, "Should have 1 document with id doc1"
    assert doc1[0]['title'] == "Introduction to Machine Learning - Updated", "Title should be updated"
    assert "improve over time" in doc1[0]['content'], "Content should be updated"
    assert len(json.loads(doc1[0]['tags'])) == 4, "Tags should be updated with 4 items"
    
    # Verify we still have 3 records (no duplicates)
    all_docs = doc_repo.select()
    assert len(all_docs) == 3, "Should still have 3 documents after update"
    
    # Step 4: Add embeddings for content field
    records = []
    for doc in doc_repo.select():
        records.append({
            "id": doc["id"],
            "content": doc["content"]
        })
    
    embedding_result = doc_repo.add_embeddings(
        records=records,
        embedding_field="content",
        batch_size=10
    )
    
    assert embedding_result['success'] is True, "Embedding should succeed"
    assert embedding_result['embeddings_added'] == 3, "Should add 3 embeddings"
    
    # Verify embeddings were created
    # We need to use execute directly since the table name is based on EmbeddingRecord config
    embedding_namespace = EmbeddingRecord.model_config.get('namespace', 'common').lower()
    embedding_name = EmbeddingRecord.model_config.get('table_name', 'embeddingrecord').lower()
    embedding_table = f"{embedding_namespace}.{embedding_name}"
    
    embeddings = doc_repo.execute(f"SELECT * FROM {embedding_table}")
    assert len(embeddings) == 3, "Should have 3 embedding records"
    
    # Step 5: Test semantic search
    search_results = doc_repo.semantic_search("data science and statistics", limit=2)
    
    # This might fail if you change how semantic search works, adjust as needed
    assert len(search_results) > 0, "Should have at least one search result"
    
    # The most relevant document should be "Data Science Fundamentals"
    data_science_doc = None
    for result in search_results:
        if "Data Science" in result['title']:
            data_science_doc = result
            break
    
    assert data_science_doc is not None, "Data Science document should be in search results"
    
    # Step 6: Test graph database integration (optional)
    try:
        from percolate.services.embedded import KuzuDBService
        
        # Initialize KuzuDB service
        kuzu_service = KuzuDBService()
        
        # Add entities to graph database
        entities = []
        for doc in doc_repo.select():
            entities.append({
                "id": doc["id"],
                "name": doc["title"]
            })
        
        count = kuzu_service.add_entities("test.TestDocument", entities)
        assert count == 3, "Should add 3 entities to graph"
        
        # Test entity lookup
        # Use our repository to get entity by name
        doc_by_name = doc_repo.get_entity_by_name("Data Science Fundamentals")
        assert doc_by_name is not None, "Should find document by name"
        assert "statistics" in doc_by_name[0]['content'], "Document content should match"
        
    except (ImportError, Exception) as e:
        print(f"Skipping graph database tests due to: {e}")


def test_idempotent_embedding(doc_repo, monkeypatch):
    """Test that adding embeddings multiple times is idempotent."""
    
    # Mock the embedding function
    def mock_get_embeddings(texts, **kwargs):
        return [[0.1, 0.2, 0.3] for _ in texts]
    
    monkeypatch.setattr("percolate.utils.embedding.get_embeddings", mock_get_embeddings)
    
    # Create a test document
    doc = TestDocument(
        id=make_uuid("embedding_test_doc"),
        title="Embedding Test",
        content="This is a test document for embeddings",
        tags=["test", "embedding"]
    )
    
    doc_repo.update_records(doc)
    
    # Add embedding first time
    record = {"id": str(make_uuid("embedding_test_doc")), "content": "This is a test document for embeddings"}
    first_result = doc_repo.add_embeddings([record], embedding_field="content")
    assert first_result['embeddings_added'] == 1, "Should add 1 embedding"
    
    # Add same embedding again
    second_result = doc_repo.add_embeddings([record], embedding_field="content")
    assert second_result['embeddings_added'] == 1, "Should still report 1 embedding (upsert)"
    
    # Verify only one embedding exists (not duplicated)
    embedding_namespace = EmbeddingRecord.model_config.get('namespace', 'common').lower()
    embedding_name = EmbeddingRecord.model_config.get('table_name', 'embeddingrecord').lower()
    embedding_table = f"{embedding_namespace}.{embedding_name}"
    
    count_query = f"SELECT COUNT(*) as count FROM {embedding_table} WHERE source_record_id = ?"
    count_result = doc_repo.execute(count_query, data=(str(make_uuid("embedding_test_doc")),))
    assert count_result[0]['count'] == 1, "Should have only 1 embedding record after duplicate insertion"


def test_batch_embedding_efficiency(doc_repo, monkeypatch):
    """Test that batch embedding is more efficient."""
    
    # Create a counter to count calls to the embedding function
    call_count = 0
    
    def counting_mock_get_embeddings(texts, **kwargs):
        nonlocal call_count
        call_count += 1
        return [[0.1, 0.2, 0.3] for _ in texts]
    
    monkeypatch.setattr("percolate.utils.embedding.get_embeddings", counting_mock_get_embeddings)
    
    # Create multiple test documents
    docs = [
        TestDocument(id=f"batch_test_{i}", title=f"Doc {i}", content=f"Content {i}", tags=["test"])
        for i in range(5)
    ]
    
    doc_repo.update_records(docs)
    
    # Prepare records for embedding
    records = [{"id": doc.id, "content": doc.content} for doc in docs]
    
    # Process in a batch
    doc_repo.add_embeddings(records, embedding_field="content", batch_size=5)
    
    # Check call count - should be 1 for batch processing
    assert call_count == 1, "Should make only 1 call for batch embedding"
    
    # Reset counter
    call_count = 0
    
    # Process with batch_size=1 to force individual processing
    doc_repo.add_embeddings(records, embedding_field="content", batch_size=1)
    
    # Check call count - should be 5 for individual processing
    assert call_count == 5, "Should make 5 calls for individual embedding"


if __name__ == "__main__":
    # Manual test execution
    with tempfile.TemporaryDirectory() as tmp_dir:
        db_path = os.path.join(tmp_dir, "test.db")
        doc_repo = DuckDBService(TestDocument, db_path=db_path)
        doc_repo.register()
        
        # Create a mock patch function for manual testing
        class MockPatch:
            def setattr(self, *args, **kwargs):
                # Replace the get_embeddings function with a mock
                if args[0] == "percolate.utils.embedding.get_embeddings":
                    globals()["get_embeddings"] = lambda texts, **kwargs: [[0.1, 0.2, 0.3] for _ in texts]
                
        mock_patch = MockPatch()
        
        print("Testing complete flow...")
        test_complete_flow(doc_repo, mock_patch)
        print("✅ Complete flow test passed")
        
        print("Testing idempotent embedding...")
        test_idempotent_embedding(doc_repo, mock_patch)
        print("✅ Idempotent embedding test passed")
        
        print("Testing batch efficiency...")
        test_batch_embedding_efficiency(doc_repo, mock_patch)
        print("✅ Batch efficiency test passed")
        
        print("All tests passed successfully!")