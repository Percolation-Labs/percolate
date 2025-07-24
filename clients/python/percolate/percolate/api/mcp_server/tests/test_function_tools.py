"""Test function search and evaluation tools"""

import pytest
from unittest.mock import patch, Mock
from percolate_mcp.tools.function_tools import create_function_tools


@pytest.mark.asyncio
async def test_function_search_success(mock_mcp, mock_client_manager):
    """Test successful function search"""
    mock_functions = {
        "query": "web search",
        "functions": [
            {
                "name": "web_search",
                "description": "Search the web for information",
                "parameters": {
                    "query": {
                        "type": "string",
                        "description": "Search query",
                        "required": True
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Max results",
                        "required": False
                    }
                }
            },
            {
                "name": "search_entities",
                "description": "Search for entities in the knowledge base",
                "parameters": {
                    "query": {"type": "string", "description": "Search text"}
                }
            }
        ]
    }
    mock_client_manager.search_and_evaluate_functions.return_value = mock_functions
    
    tools = [t for t in mock_mcp.tools if t.name == "function_search_eval"]
    function_tool = tools[0].function
    
    with patch("percolate_mcp.tools.function_tools.get_client_manager", return_value=mock_client_manager):
        result = await function_tool(query="web search")
    
    assert "Function Search Results" in result
    assert "Found 2 functions" in result
    assert "web_search" in result
    assert "search_entities" in result
    assert "[Required]" in result  # For required parameter
    mock_client_manager.search_and_evaluate_functions.assert_called_once_with("web search", False, None)


@pytest.mark.asyncio
async def test_function_search_no_results(mock_mcp, mock_client_manager):
    """Test function search with no results"""
    mock_client_manager.search_and_evaluate_functions.return_value = {
        "query": "nonexistent",
        "functions": []
    }
    
    tools = [t for t in mock_mcp.tools if t.name == "function_search_eval"]
    function_tool = tools[0].function
    
    with patch("percolate_mcp.tools.function_tools.get_client_manager", return_value=mock_client_manager):
        result = await function_tool(query="nonexistent")
    
    assert "No functions found" in result


@pytest.mark.asyncio
async def test_function_evaluation_success(mock_mcp, mock_client_manager):
    """Test successful function evaluation"""
    mock_result = {
        "query": "calculate",
        "functions": [
            {
                "name": "calculate_sum",
                "description": "Calculate sum of numbers",
                "parameters": {"numbers": {"type": "array"}}
            }
        ],
        "evaluation": {
            "function": "calculate_sum",
            "params": {"numbers": [1, 2, 3]},
            "result": "6"
        }
    }
    mock_client_manager.search_and_evaluate_functions.return_value = mock_result
    
    tools = [t for t in mock_mcp.tools if t.name == "function_search_eval"]
    function_tool = tools[0].function
    
    with patch("percolate_mcp.tools.function_tools.get_client_manager", return_value=mock_client_manager):
        result = await function_tool(
            query="calculate",
            evaluate=True,
            params={"numbers": [1, 2, 3]}
        )
    
    assert "Function Evaluation" in result
    assert "calculate_sum" in result
    assert "✅ **Result**" in result
    assert "6" in result
    mock_client_manager.search_and_evaluate_functions.assert_called_once_with(
        "calculate", True, {"numbers": [1, 2, 3]}
    )


@pytest.mark.asyncio
async def test_function_evaluation_error(mock_mcp, mock_client_manager):
    """Test function evaluation with error"""
    mock_result = {
        "query": "failing",
        "functions": [{"name": "failing_function", "description": "A function that fails"}],
        "evaluation": {
            "function": "failing_function",
            "params": {"bad": "param"},
            "error": "Invalid parameter 'bad'"
        }
    }
    mock_client_manager.search_and_evaluate_functions.return_value = mock_result
    
    tools = [t for t in mock_mcp.tools if t.name == "function_search_eval"]
    function_tool = tools[0].function
    
    with patch("percolate_mcp.tools.function_tools.get_client_manager", return_value=mock_client_manager):
        result = await function_tool(query="failing", evaluate=True, params={"bad": "param"})
    
    assert "Function Evaluation" in result
    assert "❌ **Error**" in result
    assert "Invalid parameter 'bad'" in result


@pytest.mark.asyncio
async def test_function_search_error(mock_mcp, mock_client_manager):
    """Test function search error handling"""
    mock_client_manager.search_and_evaluate_functions.return_value = {
        "error": "Function manager not initialized"
    }
    
    tools = [t for t in mock_mcp.tools if t.name == "function_search_eval"]
    function_tool = tools[0].function
    
    with patch("percolate_mcp.tools.function_tools.get_client_manager", return_value=mock_client_manager):
        result = await function_tool(query="test")
    
    assert "❌ Error:" in result
    assert "Function manager not initialized" in result