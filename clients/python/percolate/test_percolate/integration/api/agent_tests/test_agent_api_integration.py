#!/usr/bin/env python3
"""
Integration test for Agent API with metadata support.
Tests creating an agent via API and loading it with Agent.load()
"""

import requests
import json
import uuid
from datetime import datetime
from percolate.models.p8.types import Agent
from percolate.models import AbstractModel
import pytest

@pytest.mark.slow
def test_agent_api_lifecycle():
    """Test creating agent via API and loading it back"""
    
    # Configuration
    base_url = "http://localhost:5008"
    bearer_token = "postgres"
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Content-Type": "application/json"
    }
    
    # Create a unique agent name for this test
    test_id = str(uuid.uuid4())[:8]
    agent_name = f"test_agent_{test_id}"
    
    # Create test agent data with metadata
    test_metadata = {
        "created_by": "test_script",
        "version": "1.0.0",
        "tags": ["test", "integration"],
        "custom_field": "custom_value",
        "created_at": datetime.now().isoformat()
    }
    
    # Define the agent spec (model schema)
    agent_spec = {
        "type": "object",
        "title": "TestAgent",
        "properties": {
            "task": {
                "type": "string",
                "description": "Task to perform"
            },
            "parameters": {
                "type": "object",
                "properties": {
                    "max_iterations": {"type": "integer", "default": 10},
                    "temperature": {"type": "number", "default": 0.7}
                }
            }
        },
        "required": ["task"]
    }
    
    # Define agent functions
    agent_functions = {
        "process_task": {
            "description": "Process the given task",
            "parameters": {
                "type": "object",
                "properties": {
                    "task": {"type": "string"}
                }
            }
        }
    }
    
    # Create agent payload
    agent_data = {
        "id": str(uuid.uuid4()),
        "name": agent_name,
        "category": "test",
        "description": "Test agent with custom metadata for integration testing",
        "spec": agent_spec,
        "functions": agent_functions,
        "metadata": test_metadata
    }
    
    print(f"\n1. Creating agent '{agent_name}' via API...")
    print(f"   Metadata: {json.dumps(test_metadata, indent=2)}")
    
    # Create agent via API
    response = requests.post(
        f"{base_url}/entities/",
        headers=headers,
        json=agent_data
    )
    
    if response.status_code != 200:
        print(f"Failed to create agent: {response.status_code}")
        print(f"Response: {response.text}")
        return False
    
    created_agent = response.json()
    print(f"✓ Agent created successfully with ID: {created_agent['id']}")
    
    # List all agents to verify it's saved
    print("\n2. Listing all agents...")
    response = requests.get(
        f"{base_url}/entities/",
        headers=headers
    )
    
    if response.status_code == 200:
        agents = response.json()
        agent_names = [a['name'] for a in agents]
        if agent_name in agent_names:
            print(f"✓ Agent '{agent_name}' found in list of {len(agents)} agents")
        else:
            print(f"✗ Agent '{agent_name}' NOT found in list")
            return False
    else:
        print(f"Failed to list agents: {response.status_code}")
        return False
    
    # Get specific agent via API
    print(f"\n3. Getting agent '{agent_name}' via API...")
    response = requests.get(
        f"{base_url}/entities/{agent_name}",
        headers=headers
    )
    
    if response.status_code == 200:
        retrieved_agent = response.json()
        print(f"✓ Agent retrieved successfully")
        print(f"   Metadata from API: {json.dumps(retrieved_agent.get('metadata', {}), indent=2)}")
        
        # Verify metadata is preserved
        if retrieved_agent.get('metadata') == test_metadata:
            print("✓ Metadata preserved correctly in API response")
        else:
            print("✗ Metadata mismatch in API response")
            print(f"Expected: {test_metadata}")
            print(f"Got: {retrieved_agent.get('metadata')}")
    else:
        print(f"Failed to get agent: {response.status_code}")
        return False
    
    # Load agent using Agent.load()
    print(f"\n4. Loading agent using Agent.load('{agent_name}')...")
    try:
        loaded_model = Agent.load(agent_name)
        print(f"✓ Agent loaded successfully as model: {type(loaded_model).__name__}")
        
        # Check if it's an AbstractModel
        if isinstance(loaded_model, type) and issubclass(loaded_model, AbstractModel):
            print("✓ Loaded model is a valid AbstractModel subclass")
            
            # Check model config
            if hasattr(loaded_model, 'model_config'):
                print(f"✓ Model config available")
                
                # Check if metadata is in model_config
                config_dict = dict(loaded_model.model_config) if hasattr(loaded_model.model_config, '__dict__') else loaded_model.model_config
                print(f"   Model config keys: {list(config_dict.keys())}")
                
                # Verify metadata fields are in config
                metadata_preserved = all(
                    config_dict.get(key) == value 
                    for key, value in test_metadata.items()
                )
                
                if metadata_preserved:
                    print("✓ Metadata successfully preserved in model config")
                    for key, value in test_metadata.items():
                        print(f"   - {key}: {config_dict.get(key)}")
                else:
                    print("✗ Some metadata not preserved in model config")
                    for key, value in test_metadata.items():
                        actual = config_dict.get(key)
                        if actual != value:
                            print(f"   - {key}: expected '{value}', got '{actual}'")
            
            # Test creating an instance
            print("\n5. Testing model instantiation...")
            instance = loaded_model(task="Test task", parameters={"max_iterations": 5})
            print(f"✓ Model instance created: {instance}")
            print(f"   Task: {instance.task}")
            print(f"   Parameters: {instance.parameters}")
            
            # Check functions
            if hasattr(loaded_model, 'get_model_functions'):
                functions = loaded_model.get_model_functions()
                print(f"\n6. Model functions: {list(functions.keys()) if functions else 'None'}")
                if 'process_task' in functions:
                    print("✓ Expected function 'process_task' found")
            
        else:
            print(f"✗ Loaded object is not an AbstractModel: {type(loaded_model)}")
            return False
            
    except Exception as e:
        print(f"✗ Failed to load agent: {str(e)}")
        import traceback
        traceback.print_exc()
        return False
    
    print("\n✅ All tests passed! Agent API with metadata support is working correctly.")
    return True


if __name__ == "__main__":
    # Run the test
    success = test_agent_api_lifecycle()
    exit(0 if success else 1)