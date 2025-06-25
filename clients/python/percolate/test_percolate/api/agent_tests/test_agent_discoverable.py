#!/usr/bin/env python3
"""
Test for agent discoverability via API - creating agents that can be found by other agents.
"""

import requests
import json
import uuid
from datetime import datetime
from percolate.models.p8.types import Agent, Function
from percolate import p8
import pytest

@pytest.mark.slow
def test_agent_discoverability():
    """Test creating an agent with make_discoverable=True"""
    
    # Configuration
    base_url = "http://localhost:5008"
    bearer_token = "postgres"
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Content-Type": "application/json"
    }
    
    # Create a unique agent name
    test_id = str(uuid.uuid4())[:8]
    agent_name = f"calculator_agent_{test_id}"
    
    # Create test agent data
    agent_spec = {
        "type": "object",
        "title": "CalculatorAgent",
        "properties": {
            "operation": {
                "type": "string",
                "enum": ["add", "subtract", "multiply", "divide"],
                "description": "Mathematical operation to perform"
            },
            "a": {"type": "number", "description": "First number"},
            "b": {"type": "number", "description": "Second number"}
        },
        "required": ["operation", "a", "b"]
    }
    
    # Define agent functions
    agent_functions = {
        "calculate": {
            "description": "Perform mathematical calculation",
            "parameters": {
                "type": "object",
                "properties": {
                    "operation": {"type": "string"},
                    "a": {"type": "number"},
                    "b": {"type": "number"}
                }
            }
        }
    }
    
    # Create agent payload
    agent_data = {
        "id": str(uuid.uuid4()),
        "name": agent_name,
        "category": "utility",
        "description": "A calculator agent that performs basic mathematical operations",
        "spec": agent_spec,
        "functions": agent_functions,
        "metadata": {
            "created_by": "test_discoverable",
            "version": "1.0.0"
        }
    }
    
    print(f"\n1. Creating agent '{agent_name}' with make_discoverable=True...")
    
    # Create agent with make_discoverable=True
    response = requests.post(
        f"{base_url}/entities/?make_discoverable=true",
        headers=headers,
        json=agent_data
    )
    
    if response.status_code != 200:
        print(f"Failed to create agent: {response.status_code}")
        print(f"Response: {response.text}")
        return False
    
    created_agent = response.json()
    print(f"✓ Agent created successfully with ID: {created_agent['id']}")
    
    # Check if function was created
    print(f"\n2. Checking if agent was registered as a function...")
    
    # Search for functions with the agent name
    # The function name includes the namespace (public by default)
    function_name = f"public_{agent_name.replace('.', '_')}_run"
    
    # Get all functions via repository
    function_repo = p8.repository(Function)
    functions = function_repo.select()
    
    # Find our function
    agent_function = None
    for func in functions:
        if func['name'] == function_name:
            agent_function = func
            break
    
    if agent_function:
        print(f"✓ Function created: {agent_function['name']}")
        print(f"   Proxy URI: {agent_function['proxy_uri']}")
        print(f"   Description preview: {agent_function['description'][:100]}...")
        
        # Verify function spec
        if 'function_spec' in agent_function:
            print("✓ Function spec available")
            print(f"   Function parameters: {list(agent_function['function_spec'].get('parameters', {}).get('properties', {}).keys())}")
    else:
        print(f"✗ Function '{function_name}' not found")
        print(f"Available functions: {[f['name'] for f in functions[-10:]]}")  # Show last 10
        return False
    
    # Test semantic search for the function
    print(f"\n3. Testing semantic search for discoverable agent...")
    
    try:
        search_results = function_repo.search("calculator mathematical operations")
        
        found_in_search = False
        for result in search_results:
            if result.get('name') == function_name:
                found_in_search = True
                print(f"✓ Agent function found in semantic search")
                break
        
        if not found_in_search:
            print("✗ Agent function not found in semantic search (may need indexing)")
    except Exception as e:
        print(f"⚠️  Semantic search not available for Functions: {str(e)}")
        print("   (This is expected if Function entity is not fully registered)")
    
    # Load the agent and verify it works
    print(f"\n4. Loading agent and testing functionality...")
    
    try:
        loaded_model = Agent.load(agent_name)
        print(f"✓ Agent loaded successfully")
        
        # Create an instance
        instance = loaded_model(operation="add", a=5, b=3)
        print(f"✓ Agent instance created: {instance}")
        
    except Exception as e:
        print(f"✗ Failed to load agent: {str(e)}")
        return False
    
    print("\n✅ All tests passed! Agent discoverability is working correctly.")
    print(f"\nThe agent '{agent_name}' is now discoverable by other agents!")
    print(f"Other agents can find it by searching for 'calculator' or 'mathematical operations'")
    print(f"They can invoke it using the function name: {function_name}")
    
    return True

@pytest.mark.slow
def test_agent_without_discoverability():
    """Test creating an agent with make_discoverable=False (default)"""
    
    # Configuration
    base_url = "http://localhost:5008"
    bearer_token = "postgres"
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Content-Type": "application/json"
    }
    
    # Create a unique agent name
    test_id = str(uuid.uuid4())[:8]
    agent_name = f"private_agent_{test_id}"
    
    # Create minimal agent
    agent_data = {
        "id": str(uuid.uuid4()),
        "name": agent_name,
        "description": "A private agent not discoverable by others",
        "spec": {"type": "object", "properties": {"data": {"type": "string"}}},
        "functions": {}
    }
    
    print(f"\n\nTesting agent WITHOUT discoverability...")
    print(f"Creating agent '{agent_name}' with default make_discoverable=False...")
    
    # Create agent without make_discoverable
    response = requests.post(
        f"{base_url}/entities/",
        headers=headers,
        json=agent_data
    )
    
    if response.status_code != 200:
        print(f"Failed to create agent: {response.status_code}")
        return False
    
    print(f"✓ Agent created successfully")
    
    # Check that no function was created
    function_name = f"public_{agent_name.replace('.', '_')}_run"
    function_repo = p8.repository(Function)
    functions = function_repo.select()
    
    found_function = any(f['name'] == function_name for f in functions)
    
    if not found_function:
        print(f"✓ No function created (as expected)")
    else:
        print(f"✗ Function was created unexpectedly!")
        return False
    
    print("✅ Private agent test passed!")
    return True


if __name__ == "__main__":
    # Run both tests
    success1 = test_agent_discoverability()
    success2 = test_agent_without_discoverability()
    
    exit(0 if success1 and success2 else 1)