"""Integration test for help system with p8.Function listing"""

import pytest
import asyncio
from percolate.api.mcp_server.database_repository import DatabaseRepository
from percolate.api.mcp_server.api_repository import APIProxyRepository
from percolate.api.mcp_server.config import get_mcp_settings
from percolate.utils import logger
import os


@pytest.mark.asyncio
async def test_help_lists_functions_database_mode():
    """Test that help system lists available functions using database repository"""
    # Skip if not in database mode
    if os.getenv('P8_USE_API_MODE', 'true').lower() == 'true':
        pytest.skip("Database mode test - skipping in API mode")
    
    # Create database repository
    repo = DatabaseRepository(
        user_id=os.getenv('P8_USER_ID', 'test-user'),
        user_email=os.getenv('P8_USER_EMAIL', 'test@example.com')
    )
    
    # Test help query about functions
    result = await repo.get_help("What functions are available?")
    
    # Verify result contains function information
    assert result is not None
    assert isinstance(result, str)
    assert "Available Functions" in result or "function" in result.lower()
    
    # Test specific function help
    result2 = await repo.get_help("How do I use functions?", context="I want to evaluate functions")
    assert result2 is not None
    assert isinstance(result2, str)


@pytest.mark.asyncio
async def test_help_lists_functions_api_mode():
    """Test that help system lists available functions using API repository"""
    # Skip if not in API mode
    if os.getenv('P8_USE_API_MODE', 'true').lower() != 'true':
        pytest.skip("API mode test - skipping in database mode")
    
    settings = get_mcp_settings()
    
    # Create API repository
    repo = APIProxyRepository(
        api_endpoint=settings.api_endpoint,
        api_key=settings.api_key,
        user_email=settings.user_email
    )
    
    try:
        # Test help query about functions
        result = await repo.get_help("What functions are available?")
        
        # Verify result contains function information
        assert result is not None
        assert isinstance(result, str)
        assert "Available Functions" in result or "function" in result.lower()
        
        # Test specific function help
        result2 = await repo.get_help("Help me understand the available functions")
        assert result2 is not None
        assert isinstance(result2, str)
        
    finally:
        await repo.close()


@pytest.mark.asyncio
async def test_list_entities_p8_function():
    """Test that list_entities returns p8.Function entities correctly"""
    settings = get_mcp_settings()
    
    if settings.use_api_mode:
        # Test API repository
        repo = APIProxyRepository(
            api_endpoint=settings.api_endpoint,
            api_key=settings.api_key,
            user_email=settings.user_email
        )
        try:
            functions = await repo.list_entities('p8.Function', limit=10)
            assert isinstance(functions, list)
            
            # Check structure of returned functions
            for func in functions:
                assert isinstance(func, dict)
                assert 'name' in func
                assert 'description' in func
                assert 'parameters' in func
                assert 'entity_type' in func
                assert func['entity_type'] == 'p8.Function'
                
        finally:
            await repo.close()
    else:
        # Test database repository
        repo = DatabaseRepository(
            user_id=settings.user_id,
            user_email=settings.user_email
        )
        
        functions = await repo.list_entities('p8.Function', limit=10)
        assert isinstance(functions, list)
        
        # Check structure of returned functions
        for func in functions:
            assert isinstance(func, dict)
            assert 'name' in func
            assert 'description' in func
            assert 'parameters' in func
            assert 'entity_type' in func
            assert func['entity_type'] == 'p8.Function'


@pytest.mark.asyncio
async def test_help_integrates_function_context():
    """Test that help system integrates function list into context"""
    settings = get_mcp_settings()
    
    if settings.use_api_mode:
        repo = APIProxyRepository(
            api_endpoint=settings.api_endpoint,
            api_key=settings.api_key,
            user_email=settings.user_email
        )
    else:
        repo = DatabaseRepository(
            user_id=settings.user_id,
            user_email=settings.user_email
        )
    
    try:
        # First list functions directly
        functions = await repo.list_entities('p8.Function', limit=5)
        assert len(functions) > 0, "Should have at least one function available"
        
        # Now test help with function-related query
        result = await repo.get_help("What can I do with the available functions?")
        
        # Verify the help includes function information
        assert result is not None
        assert isinstance(result, str)
        
        # Check if at least one function from the list appears in help
        function_names = [f['name'] for f in functions if 'name' in f]
        assert any(fname in result for fname in function_names), \
            "Help should include at least one function from the available list"
        
    finally:
        if hasattr(repo, 'close'):
            await repo.close()


if __name__ == "__main__":
    # Run the tests
    asyncio.run(test_list_entities_p8_function())
    asyncio.run(test_help_lists_functions_api_mode())
    asyncio.run(test_help_integrates_function_context())