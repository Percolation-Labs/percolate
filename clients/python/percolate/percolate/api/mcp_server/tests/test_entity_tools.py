"""Test entity tools functionality"""

import pytest
from unittest.mock import patch
from percolate_mcp.tools.entity_tools import create_entity_tools


@pytest.mark.asyncio
async def test_get_entity_success(mock_mcp, mock_client_manager):
    """Test successful entity retrieval"""
    # Mock entity data
    mock_entity = {
        "id": "entity-123",
        "type": "Model",
        "name": "Test Model",
        "description": "A test model for unit testing",
        "tags": ["test", "model"],
        "created_at": "2024-01-01T00:00:00Z"
    }
    mock_client_manager.get_entity.return_value = mock_entity
    
    # Get the tool function
    tools = [t for t in mock_mcp.tools if t.name == "get_entity"]
    assert len(tools) == 1
    get_entity_tool = tools[0].function
    
    # Execute tool
    with patch("percolate_mcp.tools.entity_tools.get_client_manager", return_value=mock_client_manager):
        result = await get_entity_tool(entity_id="entity-123", entity_type="Model")
    
    # Verify
    assert "Entity Found" in result
    assert "entity-123" in result
    assert "Test Model" in result
    assert "A test model for unit testing" in result
    mock_client_manager.get_entity.assert_called_once_with("entity-123", "Model")


@pytest.mark.asyncio
async def test_get_entity_not_found(mock_mcp, mock_client_manager):
    """Test entity not found"""
    mock_client_manager.get_entity.return_value = {"error": "Entity not-found not found"}
    
    tools = [t for t in mock_mcp.tools if t.name == "get_entity"]
    get_entity_tool = tools[0].function
    
    with patch("percolate_mcp.tools.entity_tools.get_client_manager", return_value=mock_client_manager):
        result = await get_entity_tool(entity_id="not-found")
    
    assert "❌ Error:" in result
    assert "Entity not-found not found" in result


@pytest.mark.asyncio
async def test_entity_search_success(mock_mcp, mock_client_manager):
    """Test successful entity search"""
    mock_results = [
        {
            "id": "entity-1",
            "type": "Model", 
            "name": "Model 1",
            "description": "First test model",
            "tags": ["ml", "test"]
        },
        {
            "id": "entity-2",
            "type": "Dataset",
            "name": "Dataset 1",
            "description": "Test dataset with sample data"
        }
    ]
    mock_client_manager.search_entities.return_value = mock_results
    
    tools = [t for t in mock_mcp.tools if t.name == "entity_search"]
    search_tool = tools[0].function
    
    with patch("percolate_mcp.tools.entity_tools.get_client_manager", return_value=mock_client_manager):
        result = await search_tool(query="test", limit=5)
    
    assert "Entity Search Results" in result
    assert "Found 2 entities" in result
    assert "Model 1" in result
    assert "Dataset 1" in result
    assert "ml, test" in result
    mock_client_manager.search_entities.assert_called_once_with("test", None, 5)


@pytest.mark.asyncio
async def test_entity_search_with_filters(mock_mcp, mock_client_manager):
    """Test entity search with filters"""
    mock_client_manager.search_entities.return_value = []
    
    tools = [t for t in mock_mcp.tools if t.name == "entity_search"]
    search_tool = tools[0].function
    
    filters = {"type": "Model", "tags": ["production"]}
    
    with patch("percolate_mcp.tools.entity_tools.get_client_manager", return_value=mock_client_manager):
        result = await search_tool(query="ml model", filters=filters, limit=20)
    
    assert "No entities found" in result
    mock_client_manager.search_entities.assert_called_once_with("ml model", filters, 20)


@pytest.mark.asyncio
async def test_entity_search_error(mock_mcp, mock_client_manager):
    """Test entity search error handling"""
    mock_client_manager.search_entities.return_value = [{"error": "Database connection failed"}]
    
    tools = [t for t in mock_mcp.tools if t.name == "entity_search"]
    search_tool = tools[0].function
    
    with patch("percolate_mcp.tools.entity_tools.get_client_manager", return_value=mock_client_manager):
        result = await search_tool(query="test")
    
    assert "❌ Error:" in result
    assert "Database connection failed" in result