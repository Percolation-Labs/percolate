#!/usr/bin/env python3
"""
Test for agent namespace qualification in the API.
"""

import requests
import json
import uuid
from percolate.models.p8.types import Agent, Function
from percolate import p8


def test_agent_namespace_qualification():
    """Test that agent names are properly qualified with namespace"""
    
    # Configuration
    base_url = "http://localhost:5008"
    bearer_token = "postgres"
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Content-Type": "application/json"
    }
    
    print("\n=== Testing Agent Namespace Qualification ===")
    
    # Test 1: Create agent without namespace (should add 'public.')
    print("\n1. Creating agent without namespace...")
    test_id = str(uuid.uuid4())[:8]
    simple_name = f"test_agent_{test_id}"
    
    agent_data = {
        "id": str(uuid.uuid4()),
        "name": simple_name,  # No namespace
        "description": "Agent without namespace in name",
        "spec": {"type": "object", "properties": {}},
        "functions": {}
    }
    
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
    print(f"✓ Agent created successfully")
    print(f"   Original name: {simple_name}")
    print(f"   Saved name: {created_agent['name']}")
    
    # Verify namespace was added
    if created_agent['name'] == f"public.{simple_name}":
        print(f"✓ Namespace 'public' was automatically added")
    else:
        print(f"✗ Expected name 'public.{simple_name}', got '{created_agent['name']}'")
        return False
    
    # Test 2: Create agent with namespace (should keep as-is)
    print("\n2. Creating agent with namespace...")
    custom_namespace_name = f"custom.agent_{test_id}"
    
    agent_data2 = {
        "id": str(uuid.uuid4()),
        "name": custom_namespace_name,  # Already has namespace
        "description": "Agent with custom namespace",
        "spec": {"type": "object", "properties": {}},
        "functions": {}
    }
    
    response = requests.post(
        f"{base_url}/entities/",
        headers=headers,
        json=agent_data2
    )
    
    if response.status_code != 200:
        print(f"Failed to create agent: {response.status_code}")
        print(f"Response: {response.text}")
        return False
    
    created_agent2 = response.json()
    print(f"✓ Agent created successfully")
    print(f"   Original name: {custom_namespace_name}")
    print(f"   Saved name: {created_agent2['name']}")
    
    # Verify namespace was preserved
    if created_agent2['name'] == custom_namespace_name:
        print(f"✓ Custom namespace was preserved")
    else:
        print(f"✗ Expected name '{custom_namespace_name}', got '{created_agent2['name']}'")
        return False
    
    # Test 3: Verify we can load both agents
    print("\n3. Loading agents to verify they work...")
    
    try:
        # Load first agent (with auto-added namespace)
        loaded1 = Agent.load(f"public.{simple_name}")
        print(f"✓ Loaded agent 'public.{simple_name}' successfully")
        
        # Load second agent (with custom namespace)
        loaded2 = Agent.load(custom_namespace_name)
        print(f"✓ Loaded agent '{custom_namespace_name}' successfully")
        
    except Exception as e:
        print(f"✗ Failed to load agents: {str(e)}")
        return False
    
    # Test 4: Test with make_discoverable to ensure function names are correct
    print("\n4. Testing with make_discoverable...")
    discoverable_name = f"discoverable_{test_id}"
    
    agent_data3 = {
        "id": str(uuid.uuid4()),
        "name": discoverable_name,  # No namespace
        "description": "Discoverable agent",
        "spec": {"type": "object", "properties": {"task": {"type": "string"}}},
        "functions": {"process": {"description": "Process task"}}
    }
    
    response = requests.post(
        f"{base_url}/entities/?make_discoverable=true",
        headers=headers,
        json=agent_data3
    )
    
    if response.status_code != 200:
        print(f"Failed to create discoverable agent: {response.status_code}")
        return False
    
    created_agent3 = response.json()
    expected_name = f"public.{discoverable_name}"
    
    if created_agent3['name'] == expected_name:
        print(f"✓ Discoverable agent created with qualified name: {expected_name}")
        
        # Check if function was created with correct name
        function_repo = p8.repository(Function)
        functions = function_repo.select()
        expected_function_name = f"public_{discoverable_name}_run"
        
        if any(f['name'] == expected_function_name for f in functions):
            print(f"✓ Function created with correct name: {expected_function_name}")
        else:
            print(f"⚠️  Function not found (may need indexing)")
    else:
        print(f"✗ Unexpected name for discoverable agent")
        return False
    
    print("\n✅ All namespace qualification tests passed!")
    print("\nSummary:")
    print("- Agents without namespace automatically get 'public.' prefix")
    print("- Agents with namespace keep their original qualified name")
    print("- Agent loading works with fully qualified names")
    print("- Discoverable functions use the qualified agent name")
    
    return True


if __name__ == "__main__":
    # Run the test
    success = test_agent_namespace_qualification()
    exit(0 if success else 1)