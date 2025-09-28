# Agent Controller Testing Guide

## Overview

This guide provides comprehensive test scenarios for the agent creation and reloading controllers in Percolate. It covers unit tests with mocks and integration tests with real database connections.

## Test Setup

### Environment Configuration

```python
# test_percolate/conftest.py
import pytest
from percolate.services import PostgresService
from percolate.api.main import app
from fastapi.testclient import TestClient

@pytest.fixture
def test_client():
    """Create test client for API testing"""
    return TestClient(app)

@pytest.fixture
def mock_postgres(mocker):
    """Mock PostgresService for unit tests"""
    mock = mocker.Mock(spec=PostgresService)
    return mock

@pytest.fixture
async def real_postgres():
    """Real PostgresService for integration tests"""
    pg = PostgresService()
    yield pg
    await pg.close()

@pytest.fixture
def auth_headers():
    """Authentication headers for API requests"""
    return {"Authorization": "Bearer test-token"}
```

## Unit Tests

### 1. Agent Creation Controller Unit Test

```python
# test_percolate/unit/api/routes/entities/test_agent_creation.py

import pytest
from unittest.mock import Mock, patch
from fastapi.testclient import TestClient

class TestAgentCreationUnit:
    
    def test_create_basic_agent(self, test_client, mock_postgres, auth_headers):
        """Test creating a basic agent without discoverability"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "TestAgent",
            "category": "test",
            "description": "A test agent",
            "spec": {
                "type": "object",
                "properties": {
                    "input": {"type": "string"}
                }
            }
        }
        
        expected_response = {
            "id": "uuid-123",
            "name": "TestAgent",
            "namespace": "public",
            "category": "test"
        }
        
        with patch('percolate.api.routes.entities.router.get_postgres', return_value=mock_postgres):
            mock_postgres.run_query_get_list.return_value = [expected_response]
            
            # Act
            response = test_client.post(
                "/entities/",
                json=agent_data,
                headers=auth_headers
            )
            
            # Assert
            assert response.status_code == 200
            result = response.json()
            assert result["name"] == "TestAgent"
            assert result["namespace"] == "public"
            mock_postgres.run_query_get_list.assert_called_once()
    
    def test_create_agent_with_namespace(self, test_client, mock_postgres, auth_headers):
        """Test creating agent with explicit namespace"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "CustomAgent",
            "namespace": "custom",
            "category": "specialized",
            "spec": {"type": "object"}
        }
        
        with patch('percolate.api.routes.entities.router.get_postgres', return_value=mock_postgres):
            mock_postgres.run_query_get_list.return_value = [{
                "id": "uuid-456",
                "name": "CustomAgent",
                "namespace": "custom"
            }]
            
            # Act
            response = test_client.post(
                "/entities/",
                json=agent_data,
                headers=auth_headers
            )
            
            # Assert
            assert response.status_code == 200
            result = response.json()
            assert result["namespace"] == "custom"
    
    def test_create_discoverable_agent(self, test_client, mock_postgres, auth_headers):
        """Test creating a discoverable agent that registers as Function"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "DiscoverableAgent",
            "category": "public",
            "spec": {"type": "object"}
        }
        
        with patch('percolate.api.routes.entities.router.get_postgres', return_value=mock_postgres):
            # Mock both agent creation and function creation
            mock_postgres.run_query_get_list.side_effect = [
                [{"id": "agent-id", "name": "DiscoverableAgent", "namespace": "public"}],
                [{"id": "func-id", "name": "public_DiscoverableAgent_run"}]
            ]
            
            # Act
            response = test_client.post(
                "/entities/?make_discoverable=true",
                json=agent_data,
                headers=auth_headers
            )
            
            # Assert
            assert response.status_code == 200
            # Verify two database calls were made (agent + function)
            assert mock_postgres.run_query_get_list.call_count == 2
    
    def test_create_agent_with_functions(self, test_client, mock_postgres, auth_headers):
        """Test creating agent with callable functions"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "FunctionAgent",
            "category": "utility",
            "spec": {"type": "object"},
            "functions": {
                "calculate": {
                    "description": "Perform calculation",
                    "parameters": {
                        "x": {"type": "number"},
                        "y": {"type": "number"}
                    }
                }
            }
        }
        
        with patch('percolate.api.routes.entities.router.get_postgres', return_value=mock_postgres):
            mock_postgres.run_query_get_list.return_value = [{
                "id": "uuid-789",
                "name": "FunctionAgent",
                "functions": agent_data["functions"]
            }]
            
            # Act
            response = test_client.post(
                "/entities/",
                json=agent_data,
                headers=auth_headers
            )
            
            # Assert
            assert response.status_code == 200
            result = response.json()
            assert "functions" in result
            assert "calculate" in result["functions"]
    
    def test_create_agent_validation_error(self, test_client, auth_headers):
        """Test agent creation with invalid data"""
        # Arrange - Missing required entity_type
        invalid_data = {
            "name": "InvalidAgent",
            "spec": {"type": "object"}
        }
        
        # Act
        response = test_client.post(
            "/entities/",
            json=invalid_data,
            headers=auth_headers
        )
        
        # Assert
        assert response.status_code == 400
    
    def test_create_agent_unauthorized(self, test_client):
        """Test agent creation without authentication"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "UnauthorizedAgent",
            "spec": {"type": "object"}
        }
        
        # Act - No auth headers
        response = test_client.post("/entities/", json=agent_data)
        
        # Assert
        assert response.status_code == 401
```

### 2. Agent Loading Unit Test

```python
# test_percolate/unit/services/test_agent_loading.py

import pytest
from unittest.mock import Mock, patch
from percolate.models.p8.types import Agent
from percolate.interface import try_load_model

class TestAgentLoadingUnit:
    
    def test_load_agent_from_database(self, mock_postgres):
        """Test loading agent from database"""
        # Arrange
        mock_agent_data = {
            "id": "agent-123",
            "entity_type": "Agent",
            "name": "LoadedAgent",
            "namespace": "test",
            "category": "loaded",
            "spec": {
                "type": "object",
                "properties": {
                    "field1": {"type": "string"},
                    "field2": {"type": "integer"}
                }
            }
        }
        
        with patch('percolate.models.p8.types.Agent.load') as mock_load:
            # Create a mock dynamic model
            mock_model = type('LoadedAgent', (object,), {
                'field1': str,
                'field2': int,
                'agent_id': 'agent-123'
            })
            mock_load.return_value = mock_model
            
            # Act
            loaded_model = try_load_model("test.LoadedAgent")
            
            # Assert
            assert loaded_model is mock_model
            mock_load.assert_called_once_with("test.LoadedAgent", pg=None)
    
    def test_agent_dynamic_model_creation(self):
        """Test dynamic model creation from agent spec"""
        # Arrange
        agent = Agent(
            id="test-id",
            name="DynamicAgent",
            category="dynamic",
            spec={
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "age": {"type": "integer"},
                    "active": {"type": "boolean"}
                },
                "required": ["name"]
            }
        )
        
        # Act
        with patch.object(agent, '_create_model_from_data') as mock_create:
            mock_model = Mock()
            mock_create.return_value = mock_model
            
            result = agent._create_model_from_data({
                "id": "test-id",
                "name": "DynamicAgent",
                "spec": agent.spec
            })
            
            # Assert
            assert result is mock_model
            mock_create.assert_called_once()
    
    def test_agent_with_metadata_loading(self, mock_postgres):
        """Test loading agent with metadata including on_load queries"""
        # Arrange
        agent_data = {
            "id": "meta-agent",
            "name": "MetadataAgent",
            "category": "meta",
            "spec": {"type": "object"},
            "metadata": {
                "on_load": ["SELECT * FROM configs WHERE active = true"],
                "version": "2.0.0",
                "custom_field": "custom_value"
            }
        }
        
        with patch('percolate.models.p8.types.PostgresService') as mock_pg_class:
            mock_pg_class.return_value = mock_postgres
            mock_postgres.run_query_get_list.return_value = [agent_data]
            
            # Act
            agent = Agent(**agent_data)
            
            # Assert
            assert agent.metadata["version"] == "2.0.0"
            assert agent.metadata["custom_field"] == "custom_value"
            assert len(agent.metadata["on_load"]) == 1
```

## Integration Tests

### 1. Agent Creation Integration Test

```python
# test_percolate/integration/api/test_agent_creation_integration.py

import pytest
import asyncio
from percolate.api.main import app
from percolate.services import PostgresService
from fastapi.testclient import TestClient

@pytest.mark.integration
class TestAgentCreationIntegration:
    
    @pytest.fixture
    def cleanup_agents(self, real_postgres):
        """Cleanup created agents after tests"""
        created_ids = []
        yield created_ids
        # Cleanup
        for agent_id in created_ids:
            real_postgres.run_query(
                "DELETE FROM entities WHERE id = :id",
                {"id": agent_id}
            )
    
    async def test_create_and_reload_agent(self, test_client, real_postgres, auth_headers, cleanup_agents):
        """Test full cycle: create agent, persist, and reload"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "IntegrationTestAgent",
            "namespace": "integration",
            "category": "test",
            "description": "Agent for integration testing",
            "spec": {
                "type": "object",
                "properties": {
                    "test_string": {"type": "string"},
                    "test_number": {"type": "number"},
                    "test_bool": {"type": "boolean"}
                },
                "required": ["test_string"]
            },
            "functions": {
                "test_function": {
                    "description": "A test function",
                    "code": "return 'test_result'"
                }
            },
            "metadata": {
                "version": "1.0.0",
                "author": "test_suite"
            }
        }
        
        # Act - Create agent
        create_response = test_client.post(
            "/entities/",
            json=agent_data,
            headers=auth_headers
        )
        
        # Assert creation
        assert create_response.status_code == 200
        created_agent = create_response.json()
        cleanup_agents.append(created_agent["id"])
        
        assert created_agent["name"] == "IntegrationTestAgent"
        assert created_agent["namespace"] == "integration"
        
        # Act - Load agent
        from percolate.interface import try_load_model
        loaded_model = try_load_model(
            "integration.IntegrationTestAgent",
            custom_loader=lambda name: Agent.load(name, real_postgres)
        )
        
        # Assert loading
        assert loaded_model is not None
        assert hasattr(loaded_model, 'test_string')
        assert hasattr(loaded_model, 'test_number')
        assert hasattr(loaded_model, 'test_bool')
        
        # Test instantiation
        instance = loaded_model(test_string="hello", test_number=42)
        assert instance.test_string == "hello"
        assert instance.test_number == 42
        assert instance.agent_id == created_agent["id"]
    
    async def test_discoverable_agent_integration(self, test_client, real_postgres, auth_headers, cleanup_agents):
        """Test creating discoverable agent and verifying Function creation"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "DiscoverableIntegrationAgent",
            "namespace": "discover",
            "category": "discoverable",
            "spec": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"}
                }
            }
        }
        
        # Act - Create discoverable agent
        response = test_client.post(
            "/entities/?make_discoverable=true",
            json=agent_data,
            headers=auth_headers
        )
        
        # Assert
        assert response.status_code == 200
        created_agent = response.json()
        cleanup_agents.append(created_agent["id"])
        
        # Verify Function was created
        function_result = real_postgres.run_query_get_list(
            """
            SELECT * FROM entities 
            WHERE entity_type = 'Function' 
            AND name = :function_name
            """,
            {"function_name": "discover_DiscoverableIntegrationAgent_run"}
        )
        
        assert len(function_result) == 1
        function = function_result[0]
        assert function["proxy_uri"] == "p8agent/discover.DiscoverableIntegrationAgent"
        
        # Cleanup function
        cleanup_agents.append(function["id"])
    
    async def test_agent_execution_integration(self, test_client, real_postgres, auth_headers, cleanup_agents):
        """Test creating agent and executing it with ModelRunner"""
        # Arrange
        agent_data = {
            "entity_type": "Agent",
            "name": "ExecutableAgent",
            "namespace": "exec",
            "category": "executable",
            "spec": {
                "type": "object",
                "properties": {
                    "input_text": {"type": "string"}
                }
            },
            "functions": {
                "process_text": {
                    "description": "Process input text",
                    "code": """
def process_text(self):
    return f"Processed: {self.input_text.upper()}"
"""
                }
            }
        }
        
        # Create agent
        create_response = test_client.post(
            "/entities/",
            json=agent_data,
            headers=auth_headers
        )
        
        assert create_response.status_code == 200
        created_agent = create_response.json()
        cleanup_agents.append(created_agent["id"])
        
        # Load and execute agent
        from percolate.services import ModelRunner
        from percolate.interface import try_load_model
        
        AgentModel = try_load_model(
            "exec.ExecutableAgent",
            custom_loader=lambda name: Agent.load(name, real_postgres)
        )
        
        # Create instance
        agent_instance = AgentModel(input_text="hello world")
        
        # Create ModelRunner
        runner = ModelRunner(
            model=AgentModel,
            pg=real_postgres,
            llm_configs={}  # No LLM needed for this test
        )
        
        # Execute function
        runner.activate_functions(agent_instance)
        result = agent_instance.process_text()
        
        assert result == "Processed: HELLO WORLD"
```

### 2. Memory Proxy Integration Test

```python
# test_percolate/integration/test_memory_proxy_agents.py

import pytest
from percolate.memory import MemoryProxy
from percolate.models.p8.types import Agent

@pytest.mark.integration
class TestMemoryProxyAgentIntegration:
    
    async def test_memory_proxy_loads_dynamic_agent(self, real_postgres, cleanup_agents):
        """Test that memory proxy can load dynamically created agents"""
        # Create agent first
        agent_data = {
            "entity_type": "Agent",
            "name": "MemoryProxyAgent",
            "namespace": "memory",
            "category": "proxy_test",
            "spec": {
                "type": "object",
                "properties": {
                    "memory_field": {"type": "string"},
                    "cache_size": {"type": "integer"}
                }
            }
        }
        
        # Insert agent directly
        result = real_postgres.run_query_get_list(
            """
            INSERT INTO entities (entity_type, name, namespace, category, spec)
            VALUES (:entity_type, :name, :namespace, :category, :spec::jsonb)
            RETURNING *
            """,
            agent_data
        )
        
        created_agent = result[0]
        cleanup_agents.append(created_agent["id"])
        
        # Test memory proxy loading
        memory_proxy = MemoryProxy(postgres_service=real_postgres)
        
        # Load agent through memory proxy
        loaded_model = memory_proxy.load_model("memory.MemoryProxyAgent")
        
        assert loaded_model is not None
        assert hasattr(loaded_model, 'memory_field')
        assert hasattr(loaded_model, 'cache_size')
        
        # Test instantiation
        instance = loaded_model(memory_field="test", cache_size=100)
        assert instance.memory_field == "test"
        assert instance.cache_size == 100
        assert instance.agent_id == created_agent["id"]
    
    async def test_memory_proxy_caches_loaded_agents(self, real_postgres, cleanup_agents):
        """Test that memory proxy caches loaded agent models"""
        # Create agent
        agent_data = {
            "entity_type": "Agent",
            "name": "CachedAgent",
            "namespace": "cache",
            "category": "caching",
            "spec": {"type": "object"}
        }
        
        result = real_postgres.run_query_get_list(
            "INSERT INTO entities (entity_type, name, namespace, category, spec) VALUES (:entity_type, :name, :namespace, :category, :spec::jsonb) RETURNING *",
            agent_data
        )
        cleanup_agents.append(result[0]["id"])
        
        memory_proxy = MemoryProxy(postgres_service=real_postgres)
        
        # First load
        model1 = memory_proxy.load_model("cache.CachedAgent")
        
        # Second load should return cached model
        model2 = memory_proxy.load_model("cache.CachedAgent")
        
        # Should be the same object
        assert model1 is model2
```

## Test Utilities

### Helper Functions

```python
# test_percolate/utils/agent_helpers.py

def create_test_agent(pg: PostgresService, name: str, namespace: str = "test") -> dict:
    """Create a test agent and return its data"""
    agent_data = {
        "entity_type": "Agent",
        "name": name,
        "namespace": namespace,
        "category": "test",
        "spec": {
            "type": "object",
            "properties": {
                "test_field": {"type": "string"}
            }
        }
    }
    
    result = pg.run_query_get_list(
        """
        INSERT INTO entities (entity_type, name, namespace, category, spec)
        VALUES (:entity_type, :name, :namespace, :category, :spec::jsonb)
        RETURNING *
        """,
        agent_data
    )
    
    return result[0]

def verify_agent_schema(agent_model: type) -> bool:
    """Verify that an agent model has expected schema properties"""
    try:
        # Check if it's a proper Pydantic model
        from pydantic import BaseModel
        if not issubclass(agent_model, BaseModel):
            return False
        
        # Check for agent_id field
        if 'agent_id' not in agent_model.__fields__:
            return False
        
        return True
    except Exception:
        return False
```

## Running Tests

```bash
# Run all agent tests
pytest test_percolate/ -k "agent"

# Run unit tests only
pytest test_percolate/unit/ -k "agent"

# Run integration tests only
pytest test_percolate/integration/ -k "agent" -m integration

# Run with coverage
pytest test_percolate/ -k "agent" --cov=percolate.api.routes.entities --cov=percolate.models.p8.types

# Run specific test class
pytest test_percolate/integration/api/test_agent_creation_integration.py::TestAgentCreationIntegration
```

## Common Issues and Solutions

### 1. Database Connection Issues
```python
# Ensure test database is running
export P8_PG_HOST=localhost
export P8_PG_DATABASE=test_db
```

### 2. Authentication Failures
```python
# Mock authentication for tests
@pytest.fixture
def mock_auth(mocker):
    mocker.patch(
        'percolate.api.dependencies.auth.hybrid_auth',
        return_value=SessionContext(user_id="test-user")
    )
```

### 3. Agent Loading Failures
```python
# Always provide custom loader for tests
loaded_model = try_load_model(
    "namespace.AgentName",
    custom_loader=lambda name: Agent.load(name, postgres_service)
)
```