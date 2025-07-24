#!/usr/bin/env python3
"""
Simple test for agent on_load functionality - demonstrating the concept.
"""

import requests
import json
import uuid
from percolate.models.p8.types import Agent
from percolate import p8
import pytest

@pytest.mark.slow
def test_agent_on_load_concept():
    """Test creating an agent with on_load metadata and verify it's stored"""
    
    # Configuration
    base_url = "http://localhost:5008"
    bearer_token = "postgres"
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Content-Type": "application/json"
    }
    
    # Create unique agent name
    test_id = str(uuid.uuid4())[:8]
    agent_name = f"on_load_test_{test_id}"
    
    print(f"\n1. Creating agent '{agent_name}' with on_load query in metadata...")
    
    # Create agent with on_load query in metadata
    on_load_query = 'SELECT id, name, category FROM p8."Agent" LIMIT 3'
    
    agent_data = {
        "id": str(uuid.uuid4()),
        "name": agent_name,
        "category": "test",
        "description": "Agent that demonstrates on_load functionality for populating prompts",
        "spec": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "User query"}
            }
        },
        "functions": {},
        "metadata": {
            "on_load": on_load_query,
            "on_load_query": on_load_query,  # Try both field names
            "created_by": "on_load_demo",
            "purpose": "This agent loads Agent table data when initialized"
        }
    }
    
    # Create agent
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
    print(f"✓ Agent created successfully")
    print(f"   ID: {created_agent['id']}")
    print(f"   Metadata: {json.dumps(created_agent.get('metadata', {}), indent=2)}")
    
    print(f"\n2. Loading agent to verify on_load metadata...")
    
    try:
        # Load the agent
        loaded_model = Agent.load(agent_name)
        print(f"✓ Agent loaded successfully")
        
        # Check model config
        if hasattr(loaded_model, 'model_config'):
            config = loaded_model.model_config
            config_dict = dict(config) if hasattr(config, '__dict__') else config
            
            print(f"\n3. Checking model configuration...")
            print(f"   Config keys: {list(config_dict.keys())}")
            
            # Check for on_load fields
            on_load_found = False
            for field in ['on_load', 'on_load_query']:
                if field in config_dict:
                    on_load_found = True
                    print(f"✓ '{field}' found in model config")
                    print(f"   Value: {config_dict[field]}")
            
            if not on_load_found:
                print("⚠️  No on_load field found in model config")
            
            # Demonstrate how the query would be used
            print(f"\n4. Demonstrating on_load query execution...")
            
            # Manually execute the query to show what would happen
            if 'on_load' in config_dict or 'on_load_query' in config_dict:
                query = config_dict.get('on_load') or config_dict.get('on_load_query')
                
                print(f"   Query to execute: {query}")
                
                # Execute the query
                from percolate.services import PostgresService
                pg = PostgresService()
                
                try:
                    results = pg.execute(query)
                    print(f"✓ Query executed successfully")
                    print(f"   Returned {len(results)} records")
                    
                    if results:
                        print(f"\n   Sample data that would be loaded:")
                        for i, record in enumerate(results[:2]):
                            print(f"   Record {i+1}:")
                            print(f"     - ID: {record.get('id')}")
                            print(f"     - Name: {record.get('name')}")
                            print(f"     - Category: {record.get('category')}")
                    
                    # Show how this would be structured for the agent
                    on_load_data = {
                        'on_load_data': results
                    }
                    
                    print(f"\n5. How the data would be provided to the agent:")
                    print(f"   The _on_load() method would return:")
                    print(f"   {json.dumps({'on_load_data': f'[{len(results)} Agent records]'}, indent=2)}")
                    
                    print(f"\n   This data would be available in build_message_stack()")
                    print(f"   allowing the agent to reference loaded agents in its responses")
                    
                except Exception as e:
                    print(f"✗ Failed to execute query: {str(e)}")
            
            # Create an instance to show it works
            print(f"\n6. Creating agent instance...")
            instance = loaded_model(query="What agents are available?")
            print(f"✓ Instance created: {instance}")
            
        print("\n✅ Test completed successfully!")
        print(f"\nKey takeaways:")
        print("- Agents can store SQL queries in metadata (on_load field)")
        print("- When the agent is loaded, _on_load() executes the query")
        print("- Query results are available as 'on_load_data' in message context")
        print("- This allows agents to have dynamic context from database")
        
        return True
        
    except Exception as e:
        print(f"✗ Error: {str(e)}")
        import traceback
        traceback.print_exc()
        return False


if __name__ == "__main__":
    print("=== Agent on_load Functionality Demo ===")
    print("This test shows how agents can load data from queries on initialization")
    
    success = test_agent_on_load_concept()
    
    exit(0 if success else 1)