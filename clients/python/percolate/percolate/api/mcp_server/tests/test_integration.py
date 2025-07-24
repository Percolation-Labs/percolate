"""Integration tests for Percolate MCP Server using real backend"""

import os
import pytest
import asyncio
from fastmcp import FastMCP
from ..server import create_mcp_server
from ..config import MCPSettings


# Skip integration tests if no backend is configured
pytestmark = pytest.mark.skipif(
    not os.getenv("P8_API_KEY"),
    reason="Integration tests require P8_API_KEY environment variable"
)


@pytest.fixture(scope="module")
def integration_settings():
    """Get settings from environment for integration tests"""
    return MCPSettings(
        api_key=os.getenv("P8_API_KEY"),
        user_id=os.getenv("P8_USER_ID"),
        user_groups=os.getenv("P8_USER_GROUPS", "").split(",") if os.getenv("P8_USER_GROUPS") else None,
        role_level=int(os.getenv("P8_ROLE_LEVEL", "1")) if os.getenv("P8_ROLE_LEVEL") else None
    )


@pytest.fixture(scope="module")
def integration_mcp(integration_settings):
    """Create real MCP instance for integration tests"""
    # Temporarily override settings
    from .. import config
    original_get_settings = config.get_mcp_settings
    config.get_mcp_settings = lambda: integration_settings
    
    try:
        mcp = create_mcp_server()
        yield mcp
    finally:
        # Restore original settings
        config.get_mcp_settings = original_get_settings


class TestEntityToolsIntegration:
    """Integration tests for entity tools"""
    
    @pytest.mark.asyncio
    async def test_get_entity_real(self, integration_mcp):
        """Test getting a real entity from backend"""
        # Find get_entity tool
        get_entity = next(t.function for t in integration_mcp.tools if t.name == "get_entity")
        
        # Try to get a known entity (adjust ID based on your test data)
        # This assumes you have at least one entity in your test environment
        result = await get_entity(entity_id="test-entity-1")
        
        # Basic validation - should either find entity or return proper error
        assert isinstance(result, str)
        assert ("Entity Found" in result) or ("Error" in result)
    
    @pytest.mark.asyncio
    async def test_entity_search_real(self, integration_mcp):
        """Test searching entities in real backend"""
        search_entity = next(t.function for t in integration_mcp.tools if t.name == "entity_search")
        
        # Search for entities
        result = await search_entity(query="test", limit=5)
        
        assert isinstance(result, str)
        assert ("Entity Search Results" in result) or ("No entities found" in result)
    
    @pytest.mark.asyncio
    async def test_entity_search_with_filters_real(self, integration_mcp):
        """Test entity search with filters against real backend"""
        search_entity = next(t.function for t in integration_mcp.tools if t.name == "entity_search")
        
        # Search with type filter
        result = await search_entity(
            query="model",
            filters={"type": "Model"},
            limit=3
        )
        
        assert isinstance(result, str)
        # Should mention filters were applied if results found
        if "Found" in result and "entities" in result:
            assert "Filters applied" in result


class TestFunctionToolsIntegration:
    """Integration tests for function tools"""
    
    @pytest.mark.asyncio
    async def test_function_search_real(self, integration_mcp):
        """Test function search against real backend"""
        function_tool = next(t.function for t in integration_mcp.tools if t.name == "function_search_eval")
        
        # Search for common functions
        result = await function_tool(query="search")
        
        assert isinstance(result, str)
        assert "Function Search Results" in result
        # Should find at least some search-related functions
    
    @pytest.mark.asyncio  
    async def test_function_evaluation_real(self, integration_mcp):
        """Test function evaluation if available"""
        function_tool = next(t.function for t in integration_mcp.tools if t.name == "function_search_eval")
        
        # Try to find and evaluate a simple function
        # This depends on what functions are available in your environment
        result = await function_tool(
            query="echo",  # Common test function
            evaluate=True,
            params={"message": "Hello from integration test"}
        )
        
        assert isinstance(result, str)
        # Should have evaluation section if function found
        if "Found" in result and "functions" in result:
            assert ("Function Evaluation" in result) or ("No functions found" in result)


class TestHelpToolsIntegration:
    """Integration tests for help tools"""
    
    @pytest.mark.asyncio
    async def test_help_basic_real(self, integration_mcp):
        """Test basic help query against real PercolateAgent"""
        help_tool = next(t.function for t in integration_mcp.tools if t.name == "help")
        
        # Ask a general question
        result = await help_tool(query="What is Percolate?")
        
        assert isinstance(result, str)
        assert "PercolateAgent Response" in result
        # Should get some meaningful response
        assert len(result) > 100  # Non-trivial response
    
    @pytest.mark.asyncio
    async def test_help_with_context_real(self, integration_mcp):
        """Test help with context against real backend"""
        help_tool = next(t.function for t in integration_mcp.tools if t.name == "help")
        
        result = await help_tool(
            query="How do I query data?",
            context="I want to use SQL queries in Percolate"
        )
        
        assert isinstance(result, str)
        assert "PercolateAgent Response" in result
        # Response should be contextual
        assert len(result) > 100
    
    @pytest.mark.asyncio
    async def test_help_depth_variation(self, integration_mcp):
        """Test help with different depth settings"""
        help_tool = next(t.function for t in integration_mcp.tools if t.name == "help")
        
        # Test with minimal depth
        result_shallow = await help_tool(
            query="Explain Percolate architecture",
            max_depth=1
        )
        
        # Test with deeper search
        result_deep = await help_tool(
            query="Explain Percolate architecture", 
            max_depth=5
        )
        
        assert isinstance(result_shallow, str)
        assert isinstance(result_deep, str)
        assert "max depth: 1" in result_shallow
        assert "max depth: 5" in result_deep
        
        # Deeper search might produce more comprehensive results
        # (though not guaranteed depending on the query)


class TestAuthenticationIntegration:
    """Integration tests for authentication flow"""
    
    @pytest.mark.asyncio
    async def test_auth_required_for_tools(self, integration_mcp):
        """Test that tools require authentication"""
        # This test verifies the MCP server was created with auth
        assert integration_mcp.auth is not None
        
        # Verify all tools are protected
        for tool in integration_mcp.tools:
            # Tools should be accessible with proper auth
            # (actual auth validation happens at transport layer)
            assert tool.name in ["get_entity", "entity_search", "function_search_eval", "help"]


class TestEndToEndScenarios:
    """End-to-end integration scenarios"""
    
    @pytest.mark.asyncio
    async def test_search_and_get_entity_flow(self, integration_mcp):
        """Test searching for entities and then getting specific one"""
        search_tool = next(t.function for t in integration_mcp.tools if t.name == "entity_search")
        get_tool = next(t.function for t in integration_mcp.tools if t.name == "get_entity")
        
        # First search for entities
        search_result = await search_tool(query="model", limit=1)
        
        # If we found entities, try to extract an ID and get it
        # This is a best-effort test since we don't know exact data
        if "ID:" in search_result:
            # Try to extract entity ID from search results
            lines = search_result.split('\n')
            for line in lines:
                if "ID:" in line:
                    entity_id = line.split("ID:")[-1].strip()
                    if entity_id and entity_id != "N/A":
                        # Try to get this specific entity
                        get_result = await get_tool(entity_id=entity_id)
                        assert "Entity Found" in get_result or "Error" in get_result
                        break
    
    @pytest.mark.asyncio
    async def test_help_about_functions(self, integration_mcp):
        """Test asking help about available functions"""
        help_tool = next(t.function for t in integration_mcp.tools if t.name == "help")
        function_tool = next(t.function for t in integration_mcp.tools if t.name == "function_search_eval")
        
        # Ask about functions
        help_result = await help_tool(
            query="What functions are available for data processing?"
        )
        
        # Also search for functions
        function_result = await function_tool(query="process")
        
        # Both should return valid responses
        assert isinstance(help_result, str)
        assert isinstance(function_result, str)
        assert len(help_result) > 50
        assert ("Function Search Results" in function_result) or ("No functions found" in function_result)


# Performance tests (optional, can be slow)
class TestPerformance:
    """Performance tests for integration"""
    
    @pytest.mark.asyncio
    @pytest.mark.slow
    async def test_concurrent_requests(self, integration_mcp):
        """Test handling multiple concurrent requests"""
        search_tool = next(t.function for t in integration_mcp.tools if t.name == "entity_search")
        
        # Create multiple concurrent searches
        tasks = [
            search_tool(query=f"test{i}", limit=5)
            for i in range(5)
        ]
        
        # Execute concurrently
        results = await asyncio.gather(*tasks)
        
        # All should complete successfully
        assert len(results) == 5
        for result in results:
            assert isinstance(result, str)
            assert ("Entity Search Results" in result) or ("No entities found" in result)