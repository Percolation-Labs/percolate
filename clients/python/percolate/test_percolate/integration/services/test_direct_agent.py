#!/usr/bin/env python
"""Direct test to get p8.Agent from Percolate database"""

import os
import sys

# Set up environment for Percolate database
os.environ.update({
    "P8_PG_HOST": "localhost",
    "P8_PG_PORT": "5438",
    "P8_PG_USER": "postgres",
    "P8_PG_PASSWORD": "postgres",
    "P8_PG_DATABASE": "percolate",
    "P8_API_KEY": "test-key",
    "P8_USER_EMAIL": "test@percolate.local"
})

# Import percolate after setting env vars
import percolate as p8

def test_get_agent():
    """Test getting p8.Agent entity directly"""
    try:
        # Initialize repository for Model type
        repo = p8.repository("Model")
        
        # Try to get p8.Agent
        agent = repo.get("p8.Agent")
        
        if agent:
            print("✓ Successfully retrieved p8.Agent!")
            print(f"  ID: {agent.id}")
            print(f"  Type: {agent.type}")
            print(f"  Name: {agent.name}")
            print(f"  Description: {agent.description[:100] if agent.description else 'N/A'}...")
            return True
        else:
            print("✗ p8.Agent not found")
            return False
            
    except Exception as e:
        print(f"✗ Error: {e}")
        return False

if __name__ == "__main__":
    success = test_get_agent()
    sys.exit(0 if success else 1)