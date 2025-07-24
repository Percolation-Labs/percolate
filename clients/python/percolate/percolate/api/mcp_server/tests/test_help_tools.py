"""Test help tools functionality"""

import pytest
from unittest.mock import patch
from percolate_mcp.tools.help_tools import create_help_tools


@pytest.mark.asyncio
async def test_help_basic_query(mock_mcp, mock_client_manager):
    """Test basic help query"""
    mock_response = "To create a new model in Percolate, you can use the Model.create() method with the required parameters including name, type, and configuration."
    mock_client_manager.get_help.return_value = mock_response
    
    tools = [t for t in mock_mcp.tools if t.name == "help"]
    help_tool = tools[0].function
    
    with patch("percolate_mcp.tools.help_tools.get_client_manager", return_value=mock_client_manager):
        result = await help_tool(query="How do I create a new model?")
    
    assert "PercolateAgent Response" in result
    assert mock_response in result
    assert "max depth: 3" in result  # Default depth
    mock_client_manager.get_help.assert_called_once_with(
        "How do I create a new model?", 
        None, 
        3
    )


@pytest.mark.asyncio
async def test_help_with_context(mock_mcp, mock_client_manager):
    """Test help query with additional context"""
    mock_response = "For a classification model using scikit-learn, you should set the model type to 'sklearn_classifier' and provide the appropriate configuration..."
    mock_client_manager.get_help.return_value = mock_response
    
    tools = [t for t in mock_mcp.tools if t.name == "help"]
    help_tool = tools[0].function
    
    with patch("percolate_mcp.tools.help_tools.get_client_manager", return_value=mock_client_manager):
        result = await help_tool(
            query="What configuration do I need?",
            context="I'm building a classification model with scikit-learn"
        )
    
    assert "PercolateAgent Response" in result
    assert mock_response in result
    mock_client_manager.get_help.assert_called_once_with(
        "What configuration do I need?",
        "I'm building a classification model with scikit-learn",
        3
    )


@pytest.mark.asyncio
async def test_help_with_custom_depth(mock_mcp, mock_client_manager):
    """Test help query with custom max depth"""
    mock_response = "After deep analysis across multiple sources, here's a comprehensive guide..."
    mock_client_manager.get_help.return_value = mock_response
    
    tools = [t for t in mock_mcp.tools if t.name == "help"]
    help_tool = tools[0].function
    
    with patch("percolate_mcp.tools.help_tools.get_client_manager", return_value=mock_client_manager):
        result = await help_tool(
            query="Explain the entire ML pipeline architecture",
            max_depth=5
        )
    
    assert "max depth: 5" in result
    mock_client_manager.get_help.assert_called_once_with(
        "Explain the entire ML pipeline architecture",
        None,
        5
    )


@pytest.mark.asyncio
async def test_help_error_handling(mock_mcp, mock_client_manager):
    """Test help tool error handling"""
    error_message = "Help request failed: Agent initialization error"
    mock_client_manager.get_help.return_value = error_message
    
    tools = [t for t in mock_mcp.tools if t.name == "help"]
    help_tool = tools[0].function
    
    with patch("percolate_mcp.tools.help_tools.get_client_manager", return_value=mock_client_manager):
        result = await help_tool(query="Test query")
    
    assert "PercolateAgent Response" in result
    assert "Help request failed" in result
    assert "Agent initialization error" in result


@pytest.mark.asyncio
async def test_help_formatted_output(mock_mcp, mock_client_manager):
    """Test help tool output formatting"""
    mock_response = """Here's how to work with entities:

1. **Creating Entities**: Use Entity.create()
2. **Updating Entities**: Use Entity.update()
3. **Deleting Entities**: Use Entity.delete()

For more details, see the documentation."""
    
    mock_client_manager.get_help.return_value = mock_response
    
    tools = [t for t in mock_mcp.tools if t.name == "help"]
    help_tool = tools[0].function
    
    with patch("percolate_mcp.tools.help_tools.get_client_manager", return_value=mock_client_manager):
        result = await help_tool(query="How do I work with entities?")
    
    # Check formatting preserved
    assert "💡 **PercolateAgent Response**" in result
    assert "1. **Creating Entities**" in result
    assert "2. **Updating Entities**" in result
    assert "---" in result  # Separator
    assert "*Query processed with max depth:" in result