#!/usr/bin/env python3
"""
Simple example of creating an agent with metadata and loading it back.
"""

import uuid
from percolate.models.p8.types import Agent
from percolate import p8

# Create a unique agent name
agent_name = f"weather_agent_{str(uuid.uuid4())[:8]}"

# Create an agent with custom metadata
agent = Agent(
    id=str(uuid.uuid4()),
    name=agent_name,
    category="utility",
    description="An agent that provides weather information",
    spec={
        "type": "object",
        "properties": {
            "location": {"type": "string"},
            "units": {"type": "string", "enum": ["celsius", "fahrenheit"]}
        }
    },
    functions={
        "get_weather": {
            "description": "Get weather for a location",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {"type": "string"}
                }
            }
        }
    },
    metadata={
        "author": "test_user",
        "version": "1.0.0",
        "api_key_required": True,
        "last_updated": "2025-06-22"
    }
)

# Save the agent
repo = p8.repository(Agent)
saved_agents = repo.update_records([agent])
print(f"Saved agent: {saved_agents[0]['name']}")

# Load the agent back
loaded_model = Agent.load(agent_name)
print(f"Loaded model: {type(loaded_model).__name__}")

# Access metadata from model config
print(f"Author: {loaded_model.model_config.get('author')}")
print(f"Version: {loaded_model.model_config.get('version')}")
print(f"API Key Required: {loaded_model.model_config.get('api_key_required')}")

# Create an instance
instance = loaded_model(location="San Francisco", units="celsius")
print(f"Instance created: {instance}")