"""Test configuration and fixtures for MCP integration tests"""

import pytest
import os
import asyncio
from pathlib import Path


@pytest.fixture(scope="session", autouse=True)
def setup_test_environment():
    """Set up environment variables for tests"""
    # Ensure we have the basic test environment set up
    if "P8_API_KEY" not in os.environ:
        os.environ["P8_API_KEY"] = "test-api-key-12345"
    if "P8_USER_EMAIL" not in os.environ:
        os.environ["P8_USER_EMAIL"] = "test@percolate.local"
    
    # Ensure desktop extension mode
    os.environ["P8_MCP_DESKTOP_EXT"] = "true"
    
    yield


@pytest.fixture
def event_loop():
    """Create event loop for async tests"""
    loop = asyncio.get_event_loop_policy().new_event_loop()
    yield loop
    loop.close()


# Test data fixtures
@pytest.fixture
def sample_entity_data():
    """Sample entity data for tests"""
    return {
        "id": "test-new-entity",
        "type": "Model",
        "name": "New Test Model",
        "description": "Created during test",
        "metadata": {
            "version": "1.0",
            "tags": ["test", "integration"]
        }
    }


@pytest.fixture
def sample_function_data():
    """Sample function data for tests"""
    return {
        "name": "test_function",
        "description": "Function created during test",
        "parameters": {
            "input": {
                "type": "string",
                "required": True,
                "description": "Input parameter"
            }
        }
    }


@pytest.fixture
def sample_resource_data():
    """Sample resource data for tests"""
    return {
        "name": "test_resource.json",
        "type": "data",
        "content": '{"test": "data", "value": 123}',
        "metadata": {
            "format": "json",
            "size": 30
        }
    }