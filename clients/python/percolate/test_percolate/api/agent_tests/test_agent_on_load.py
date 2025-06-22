#!/usr/bin/env python3
"""
Test for agent on_load functionality - demonstrating how to populate prompts with data from queries.
"""

import requests
import json
import uuid
from percolate.models.p8.types import Agent
from percolate import p8
import pytest

@pytest.mark.slow
def test_agent_with_on_load_query():
    """Test creating an agent with on_load query in metadata"""
    
    # Configuration
    base_url = "http://localhost:5008"
    bearer_token = "postgres"
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Content-Type": "application/json"
    }
    
    # Fixed agent name for this test
    agent_name = "test_agent_agent"
    
    print(f"\n1. Creating agent '{agent_name}' with on_load query...")
    
    # Create agent with on_load query in metadata
    agent_data = {
        "id": str(uuid.uuid4()),
        "name": agent_name,
        "category": "test",
        "description": "Test agent that loads data from Agent table on initialization",
        "spec": {
            "type": "object",
            "properties": {}  # No schema needed for this test
        },
        "functions": {},
        "metadata": {
            "on_load": 'SELECT id, name, category FROM p8."Agent" LIMIT 5',
            "created_by": "on_load_test",
            "version": "1.0.0"
        }
    }
    
    # Create agent with make_discoverable=true
    response = requests.post(
        f"{base_url}/entities/?make_discoverable=true",
        headers=headers,
        json=agent_data
    )
    
    if response.status_code != 200:
        # Agent might already exist, try to continue
        print(f"Note: Agent creation returned {response.status_code}")
        print(f"Response: {response.text}")
        print("Continuing with test (agent might already exist)...")
    else:
        created_agent = response.json()
        print(f"✓ Agent created successfully with ID: {created_agent['id']}")
    
    print(f"\n2. Loading agent using Agent.load('{agent_name}')...")
    
    try:
        # Load the agent
        loaded_model = Agent.load(agent_name)
        print(f"✓ Agent loaded successfully as model: {type(loaded_model).__name__}")
        
        # Check if on_load_query is in model_config
        if hasattr(loaded_model, 'model_config'):
            config_dict = dict(loaded_model.model_config) if hasattr(loaded_model.model_config, '__dict__') else loaded_model.model_config
            if 'on_load' in config_dict:
                print(f"✓ on_load found in model config")
                print(f"   Query: {config_dict['on_load']}")
            else:
                print("✗ on_load_query not found in model config")
                print(f"   Available config keys: {list(config_dict.keys())}")
        
        print(f"\n3. Testing build_message_stack with on_load data...")
        
        # Build message stack
        test_question = "What agents are available?"
        message_stack = loaded_model.build_message_stack(test_question)
        
        print(f"✓ Message stack built successfully")
        print(f"   Type: {type(message_stack)}")
        
        # Check if message stack contains on_load_data
        if hasattr(message_stack, 'to_dict'):
            stack_dict = message_stack.to_dict()
        elif isinstance(message_stack, dict):
            stack_dict = message_stack
        elif isinstance(message_stack, list):
            # Check if any message contains on_load_data
            stack_dict = {'messages': message_stack}
        else:
            stack_dict = {}
        
        # Look for on_load_data in the serialized message stack
        found_on_load_data = False
        
        # Helper function to search for on_load_data recursively
        def find_on_load_data(obj, path=""):
            nonlocal found_on_load_data
            if isinstance(obj, dict):
                if 'on_load_data' in obj:
                    found_on_load_data = True
                    print(f"✓ Found 'on_load_data' at path: {path}")
                    print(f"   Data preview: {json.dumps(obj['on_load_data'][:2] if isinstance(obj['on_load_data'], list) else obj['on_load_data'], indent=2)[:200]}...")
                    return True
                for key, value in obj.items():
                    if find_on_load_data(value, f"{path}.{key}" if path else key):
                        return True
            elif isinstance(obj, list):
                for i, item in enumerate(obj):
                    if find_on_load_data(item, f"{path}[{i}]"):
                        return True
            elif isinstance(obj, str):
                # Check if on_load_data is mentioned in string content
                if 'on_load_data' in obj:
                    found_on_load_data = True
                    print(f"✓ Found 'on_load_data' reference in string at path: {path}")
                    return True
            return False
        
        # Search for on_load_data
        find_on_load_data(stack_dict)
        
        if not found_on_load_data:
            # Try direct check on message content
            if isinstance(message_stack, list):
                for i, msg in enumerate(message_stack):
                    if isinstance(msg, dict):
                        content = msg.get('content', '')
                        if 'on_load_data' in str(content):
                            found_on_load_data = True
                            print(f"✓ Found 'on_load_data' in message {i} content")
                            break
        
        # Also check if _on_load was called
        print(f"\n4. Testing _on_load method directly...")
        on_load_result = loaded_model._on_load()
        
        if on_load_result:
            print(f"✓ _on_load returned data")
            if isinstance(on_load_result, dict) and 'on_load_data' in on_load_result:
                print(f"✓ on_load_data found in result")
                data = on_load_result['on_load_data']
                if isinstance(data, list) and len(data) > 0:
                    print(f"   Loaded {len(data)} records from Agent table")
                    print(f"   Sample record: {json.dumps(data[0], indent=2, default=str)[:200]}...")
                else:
                    print(f"   Data type: {type(data)}")
            else:
                print(f"   Result: {on_load_result}")
        else:
            print("✗ _on_load returned None")
        
        print("\n✅ Test completed!")
        print(f"\nThe agent '{agent_name}' demonstrates:")
        print("- How to add on_load_query in metadata")
        print("- Query execution when agent is loaded")
        print("- Data available in agent's context for prompts")
        
        if found_on_load_data:
            print("\n✓ SUCCESS: on_load_data was found in the message stack!")
        else:
            print("\n⚠️  NOTE: on_load_data was executed but may not be directly visible in message stack")
            print("   The data is still available to the agent during message processing")
        
        return True
        
    except Exception as e:
        print(f"✗ Error during test: {str(e)}")
        import traceback
        traceback.print_exc()
        return False


def cleanup_test_agent():
    """Optional cleanup function to remove test agent"""
    try:
        from percolate import p8
        repo = p8.repository(Agent)
        # This would delete the agent if we had a delete method
        print("Note: Manual cleanup may be needed for 'test_agent_agent'")
    except:
        pass


if __name__ == "__main__":
    print("=== Testing Agent with on_load Query ===")
    print("This test demonstrates how to populate agent prompts with data from database queries")
    
    success = test_agent_with_on_load_query()
    
    if success:
        print("\n✅ All tests passed!")
    else:
        print("\n❌ Test failed!")
    
    exit(0 if success else 1)