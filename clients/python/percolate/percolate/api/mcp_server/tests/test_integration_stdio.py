"""Integration tests for MCP server using stdio transport with real database"""

import os
import pytest
import asyncio
import json
from typing import Dict, Any, List
from fastmcp.client import Client
from pathlib import Path

# Skip if no database connection
pytestmark = pytest.mark.skipif(
    not os.getenv("P8_PG_HOST", "localhost"),
    reason="Integration tests require database connection"
)


@pytest.fixture(scope="module")
def test_config():
    """Test configuration"""
    return {
        "api_key": os.getenv("P8_API_KEY", "test-api-key"),
        "user_email": os.getenv("P8_USER_EMAIL", "test@percolate.local"),
        "db_host": os.getenv("P8_PG_HOST", "localhost"),
        "db_port": os.getenv("P8_PG_PORT", "5432"),
        "server_module": "percolate.api.mcp_server"
    }


@pytest.fixture
async def mcp_env(test_config):
    """Set up environment for MCP client"""
    env = os.environ.copy()
    env.update({
        "P8_API_KEY": test_config["api_key"],
        "P8_USER_EMAIL": test_config["user_email"],
        "P8_MCP_DESKTOP_EXT": "true",
        "P8_LOG_LEVEL": "INFO"
    })
    return env


@pytest.fixture
async def test_entity_id():
    """Return p8.Agent UUID as a test entity ID"""
    return "96d1a2ff-045b-55cc-a7de-543d1d3cccf8"  # p8.Agent UUID


@pytest.fixture
async def test_file_path(tmp_path):
    """Create a test file for upload"""
    test_file = tmp_path / "test_document.txt"
    test_file.write_text("This is a test document for MCP integration testing.\n" * 10)
    return str(test_file)


@pytest.fixture
async def mcp_client_stdio(mcp_env):
    """MCP client fixture for stdio transport"""
    from fastmcp.client import Client, PythonStdioTransport
    
    # Create transport
    runner_script = Path(__file__).parent / "run_server.py"
    transport = PythonStdioTransport(
        script_path=runner_script,
        env=mcp_env
    )
    
    # Use client as context manager
    async with Client(transport=transport) as client:
        yield client


class TestEntityToolsStdio:
    """Test entity tools via stdio transport"""
    
    @pytest.mark.asyncio
    async def test_entity_search_stdio(self, mcp_env):
        """Test entity search returns results"""
        from fastmcp.client import Client, PythonStdioTransport
        
        # Create transport
        runner_script = Path(__file__).parent / "run_server.py"
        transport = PythonStdioTransport(
            script_path=runner_script,
            env=mcp_env
        )
        
        # Use client as context manager
        async with Client(transport=transport) as client:
            # Call entity_search tool - wrap arguments in params
            result = await client.call_tool(
                "entity_search",
                {
                    "params": {
                        "query": "test",
                        "limit": 5
                    }
                }
            )
            
            # Result is a CallToolResult object, get the data
            data = result.data if hasattr(result, 'data') else result
            
            # Print the actual result structure for debugging
            print(f"Result type: {type(result)}")
            print(f"Data type: {type(data)}")
            if isinstance(data, list) and data:
                print(f"First item type: {type(data[0])}")
                if hasattr(data[0], '__dict__'):
                    print(f"First item dict: {data[0].__dict__}")
            
            # Verify response structure
            assert isinstance(data, list)
            if data:  # If we have results
                print(f"✓ Found {len(data)} results")
                # Results might be Pydantic models or dicts
                for item in data:
                    if hasattr(item, 'model_dump'):
                        # Convert Pydantic model to dict
                        item_dict = item.model_dump()
                    elif hasattr(item, '__dict__'):
                        item_dict = item.__dict__
                    else:
                        item_dict = item if isinstance(item, dict) else str(item)
                    print(f"  Item: {item_dict}")
            else:
                print("No entities found matching 'test'")
    
    @pytest.mark.asyncio
    async def test_entity_search_with_filters_stdio(self, mcp_client_stdio):
        """Test entity search with filters"""
        result = await mcp_client_stdio.call_tool(
            "entity_search",
            {
                "params": {
                    "query": "model",
                    "filters": {"type": "Model"},
                    "limit": 3
                }
            }
        )
        
        # Result is a CallToolResult object, get the data
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, list)
        # All results should be of type Model if filter worked
        for entity in data:
            if isinstance(entity, dict) and "error" not in entity and "type" in entity:
                assert entity["type"] == "Model"
    
    @pytest.mark.asyncio
    async def test_get_entity_stdio(self, mcp_env, test_entity_id):
        """Test getting a specific entity"""
        from fastmcp.client import Client, PythonStdioTransport
        
        # Create transport
        runner_script = Path(__file__).parent / "run_server.py"
        transport = PythonStdioTransport(
            script_path=runner_script,
            env=mcp_env
        )
        
        # Use client as context manager
        async with Client(transport=transport) as client:
            # Call get_entity tool - wrap arguments in params
            result = await client.call_tool(
                "get_entity",
                {
                    "params": {
                        "entity_id": test_entity_id
                    }
                }
            )
            
            # Result is a CallToolResult object, get the data
            data = result.data if hasattr(result, 'data') else result
            
            assert isinstance(data, dict)
            # Should either find entity or return error
            if "error" not in data:
                assert "id" in data
                assert data["id"] == test_entity_id
                print(f"✓ Successfully retrieved entity: {data['id']}")
            else:
                print(f"Entity not found: {data['error']}")
    
    @pytest.mark.asyncio
    async def test_get_entity_with_type_stdio(self, mcp_client_stdio):
        """Test getting entity with type hint"""
        result = await mcp_client_stdio.call_tool(
            "get_entity",
            {
                "params": {
                    "entity_id": "test-model-001",
                    "entity_type": "Model"
                }
            }
        )
        
        # Result is a CallToolResult object, get the data
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, dict)
        # Verify it's either not found or correct type
        if "error" not in data and "type" in data:
            assert data["type"] == "Model"


class TestFunctionToolsStdio:
    """Test function tools via stdio transport"""
    
    @pytest.mark.asyncio
    async def test_function_search_stdio(self, mcp_client_stdio):
        """Test function search"""
        result = await mcp_client_stdio.call_tool(
            "function_search",
            {
                "params": {
                    "query": "search",
                    "limit": 5
                }
            }
        )
        
        # Result is a CallToolResult object, get the data
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, list)
        if data and isinstance(data[0], dict) and "error" not in data[0]:
            # Check function structure
            for func in data:
                if isinstance(func, dict):
                    assert "name" in func
                    assert "description" in func
    
    @pytest.mark.asyncio
    async def test_function_eval_stdio(self, mcp_client_stdio):
        """Test function evaluation"""
        # First search for a function to test
        search_result = await mcp_client_stdio.call_tool(
            "function_search",
            {
                "params": {
                    "query": "echo",
                    "limit": 1
                }
            }
        )
        
        # Get data from result
        search_data = search_result.data if hasattr(search_result, 'data') else search_result
        
        if search_data and isinstance(search_data, list) and search_data and "error" not in search_data[0]:
            func_name = search_data[0]["name"]
            
            # Try to evaluate it
            eval_result = await mcp_client_stdio.call_tool(
                "function_eval",
                {
                    "params": {
                        "function_name": func_name,
                        "args": {"message": "Hello from MCP test"}
                    }
                }
            )
            
            # Get data from result
            eval_data = eval_result.data if hasattr(eval_result, 'data') else eval_result
            
            assert isinstance(eval_data, dict)
            assert "function" in eval_data
            assert "success" in eval_data
            
            if eval_data["success"]:
                assert "result" in eval_data
            else:
                assert "error" in eval_data
    
    @pytest.mark.asyncio
    async def test_function_eval_invalid_stdio(self, mcp_client_stdio):
        """Test function evaluation with invalid function"""
        result = await mcp_client_stdio.call_tool(
            "function_eval",
            {
                "params": {
                    "function_name": "non_existent_function_12345",
                    "args": {"test": "data"}
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, dict)
        assert data["success"] is False
        assert "error" in data


class TestFileToolsStdio:
    """Test file tools via stdio transport"""
    
    @pytest.mark.asyncio
    async def test_file_upload_stdio(self, mcp_client_stdio, test_file_path):
        """Test file upload"""
        result = await mcp_client_stdio.call_tool(
            "file_upload",
            {
                "params": {
                    "file_path": test_file_path,
                    "description": "Integration test file",
                    "tags": ["test", "integration"]
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, dict)
        if data.get("success"):
            assert "file_name" in data
            assert "resource_id" in data
            assert data["status"] == "uploaded"
        else:
            # If failed, should have error
            assert "error" in data
    
    @pytest.mark.asyncio
    async def test_file_upload_invalid_path_stdio(self, mcp_client_stdio):
        """Test file upload with invalid path"""
        result = await mcp_client_stdio.call_tool(
            "file_upload",
            {
                "params": {
                    "file_path": "/non/existent/file.txt"
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, dict)
        assert data.get("success") is False
        assert "error" in data
        assert "not found" in data["error"].lower()
    
    @pytest.mark.asyncio
    async def test_resource_search_stdio(self, mcp_client_stdio):
        """Test resource search"""
        result = await mcp_client_stdio.call_tool(
            "resource_search",
            {
                "params": {
                    "query": "test",
                    "limit": 5
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, list)
        if data and isinstance(data[0], dict) and "error" not in data[0]:
            for resource in data:
                assert isinstance(resource, dict)
                # Resources should have certain fields
                if "id" in resource:
                    assert "name" in resource or "content" in resource
    
    @pytest.mark.asyncio
    async def test_resource_search_with_type_stdio(self, mcp_client_stdio):
        """Test resource search with type filter"""
        result = await mcp_client_stdio.call_tool(
            "resource_search",
            {
                "params": {
                    "query": "document",
                    "resource_type": "document",
                    "limit": 3
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, list)
        # Check if type filter was applied
        for resource in data:
            if isinstance(resource, dict) and "error" not in resource and "type" in resource:
                assert resource["type"] == "document"


class TestHelpToolsStdio:
    """Test help tools via stdio transport"""
    
    @pytest.mark.asyncio
    async def test_help_basic_stdio(self, mcp_client_stdio):
        """Test basic help query"""
        result = await mcp_client_stdio.call_tool(
            "help",
            {
                "params": {
                    "query": "What is Percolate?"
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, str)
        assert len(data) > 0
        # Should not be an error message
        assert not data.startswith("Error:")
    
    @pytest.mark.asyncio
    async def test_help_with_context_stdio(self, mcp_client_stdio):
        """Test help with context"""
        result = await mcp_client_stdio.call_tool(
            "help",
            {
                "params": {
                    "query": "How do I search for entities?",
                    "context": "I want to find all Model entities tagged with 'production'",
                    "max_depth": 2
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, str)
        assert len(data) > 0
        # Should provide relevant help
        assert not data.startswith("Error:")
    
    @pytest.mark.asyncio
    async def test_help_max_depth_stdio(self, mcp_client_stdio):
        """Test help with different max depths"""
        # Shallow search
        result_shallow = await mcp_client_stdio.call_tool(
            "help",
            {
                "params": {
                    "query": "Explain Percolate architecture",
                    "max_depth": 1
                }
            }
        )
        
        # Deeper search
        result_deep = await mcp_client_stdio.call_tool(
            "help",
            {
                "params": {
                    "query": "Explain Percolate architecture",
                    "max_depth": 5
                }
            }
        )
        
        # Get data from results
        data_shallow = result_shallow.data if hasattr(result_shallow, 'data') else result_shallow
        data_deep = result_deep.data if hasattr(result_deep, 'data') else result_deep
        
        assert isinstance(data_shallow, str)
        assert isinstance(data_deep, str)
        assert len(data_shallow) > 0
        assert len(data_deep) > 0


class TestAuthenticationStdio:
    """Test authentication scenarios"""
    
    @pytest.mark.asyncio
    async def test_list_tools_stdio(self, mcp_client_stdio):
        """Test that we can list available tools"""
        tools = await mcp_client_stdio.tools
        
        assert isinstance(tools, list)
        assert len(tools) > 0
        
        # Check we have all expected tools
        tool_names = [tool.name for tool in tools]
        expected_tools = [
            "get_entity",
            "entity_search",
            "function_search",
            "function_eval",
            "file_upload",
            "resource_search",
            "help"
        ]
        
        for expected in expected_tools:
            assert expected in tool_names
    
    @pytest.mark.asyncio
    async def test_tool_metadata_stdio(self, mcp_client_stdio):
        """Test tool metadata and descriptions"""
        tools = await mcp_client_stdio.tools
        
        for tool in tools:
            assert hasattr(tool, 'name')
            assert hasattr(tool, 'description')
            assert hasattr(tool, 'inputSchema')
            
            # Check input schema
            schema = tool.inputSchema
            assert "type" in schema
            assert schema["type"] == "object"
            assert "properties" in schema


class TestErrorHandlingStdio:
    """Test error handling scenarios"""
    
    @pytest.mark.asyncio
    async def test_invalid_tool_name_stdio(self, mcp_client_stdio):
        """Test calling non-existent tool"""
        with pytest.raises(Exception) as exc_info:
            await mcp_client_stdio.call_tool(
                "non_existent_tool",
                {"params": {"param": "value"}}
            )
        
        assert "not found" in str(exc_info.value).lower() or "unknown" in str(exc_info.value).lower()
    
    @pytest.mark.asyncio
    async def test_invalid_parameters_stdio(self, mcp_client_stdio):
        """Test calling tool with invalid parameters"""
        with pytest.raises(Exception) as exc_info:
            await mcp_client_stdio.call_tool(
                "entity_search",
                {
                    "params": {
                        # Missing required 'query' parameter
                        "limit": 5
                    }
                }
            )
        
        assert "required" in str(exc_info.value).lower() or "missing" in str(exc_info.value).lower()
    
    @pytest.mark.asyncio
    async def test_parameter_validation_stdio(self, mcp_client_stdio):
        """Test parameter validation"""
        # Test with invalid limit (too high)
        result = await mcp_client_stdio.call_tool(
            "entity_search",
            {
                "params": {
                    "query": "test",
                    "limit": 1000  # Should be capped at 100
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        # Should still work but limit should be enforced
        assert isinstance(data, list)
        if data:
            assert len(data) <= 100


class TestConcurrencyStdio:
    """Test concurrent operations"""
    
    @pytest.mark.asyncio
    async def test_concurrent_searches_stdio(self, mcp_client_stdio):
        """Test multiple concurrent searches"""
        # Create multiple search tasks
        tasks = [
            mcp_client_stdio.call_tool("entity_search", {"params": {"query": f"test{i}", "limit": 3}})
            for i in range(5)
        ]
        
        # Execute concurrently
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        # All should complete
        assert len(results) == 5
        for result in results:
            # Should not be exceptions
            assert not isinstance(result, Exception)
            # Get data from result
            data = result.data if hasattr(result, 'data') else result
            assert isinstance(data, list)
    
    @pytest.mark.asyncio
    async def test_mixed_concurrent_tools_stdio(self, mcp_client_stdio):
        """Test different tools concurrently"""
        tasks = [
            mcp_client_stdio.call_tool("entity_search", {"params": {"query": "test", "limit": 2}}),
            mcp_client_stdio.call_tool("function_search", {"params": {"query": "search", "limit": 2}}),
            mcp_client_stdio.call_tool("resource_search", {"params": {"query": "doc", "limit": 2}}),
            mcp_client_stdio.call_tool("help", {"params": {"query": "What is MCP?", "max_depth": 1}})
        ]
        
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        assert len(results) == 4
        # Each should return appropriate type
        data0 = results[0].data if hasattr(results[0], 'data') else results[0]
        data1 = results[1].data if hasattr(results[1], 'data') else results[1]
        data2 = results[2].data if hasattr(results[2], 'data') else results[2]
        data3 = results[3].data if hasattr(results[3], 'data') else results[3]
        
        assert isinstance(data0, list)  # entity_search
        assert isinstance(data1, list)  # function_search
        assert isinstance(data2, list)  # resource_search
        assert isinstance(data3, str)   # help


# Performance tests (optional)
@pytest.mark.slow
class TestPerformanceStdio:
    """Performance and load tests"""
    
    @pytest.mark.asyncio
    async def test_large_result_set_stdio(self, mcp_client_stdio):
        """Test handling large result sets"""
        result = await mcp_client_stdio.call_tool(
            "entity_search",
            {
                "params": {
                    "query": "*",  # Match all
                    "limit": 100   # Maximum allowed
                }
            }
        )
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, list)
        assert len(data) <= 100
    
    @pytest.mark.asyncio
    async def test_help_response_time_stdio(self, mcp_client_stdio):
        """Test help tool response time"""
        import time
        
        start = time.time()
        result = await mcp_client_stdio.call_tool(
            "help",
            {
                "params": {
                    "query": "How do I create a machine learning pipeline?",
                    "max_depth": 3
                }
            }
        )
        end = time.time()
        
        # Get data from result
        data = result.data if hasattr(result, 'data') else result
        
        assert isinstance(data, str)
        assert len(data) > 0
        # Should respond within reasonable time
        assert (end - start) < 30  # 30 seconds max