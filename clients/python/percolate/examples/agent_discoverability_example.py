#!/usr/bin/env python3
"""
Example demonstrating how to create agents/models and make them discoverable in Percolate.

This example shows:
1. Creating a custom agent/model
2. Registering it in the database
3. Making it discoverable as a function
4. Using the agent via function calls
"""

import percolate as p8
from percolate.models import AbstractModel
from percolate.models.p8.types import Agent, Function
from pydantic import Field
import typing


# Step 1: Define a custom agent/model
class WeatherAgent(AbstractModel):
    """I am a weather information agent that can provide weather data and forecasts.
    I can help with current conditions, forecasts, and weather-related questions.
    """
    
    model_config = {
        'name': 'WeatherAgent',
        'namespace': 'examples',
        'description': 'A weather information assistant that provides current conditions and forecasts',
        'functions': {
            'get_current_weather': 'Get current weather for a location',
            'get_forecast': 'Get weather forecast for the next few days',
            'get_weather_alerts': 'Check for any weather alerts or warnings'
        }
    }
    
    location: str = Field(description="Location to get weather for")
    units: str = Field(default="metric", description="Temperature units (metric/imperial)")
    
    @classmethod
    def get_current_weather(cls, location: str, units: str = "metric") -> dict:
        """Get current weather conditions for a location
        
        Args:
            location: City name or coordinates
            units: Temperature units (metric or imperial)
        """
        # This is a mock implementation - in real use, this would call a weather API
        return {
            "location": location,
            "temperature": 22 if units == "metric" else 72,
            "units": "C" if units == "metric" else "F",
            "conditions": "Partly cloudy",
            "humidity": 65,
            "wind_speed": 10
        }
    
    @classmethod
    def get_forecast(cls, location: str, days: int = 3) -> list:
        """Get weather forecast for upcoming days
        
        Args:
            location: City name or coordinates  
            days: Number of days to forecast (1-7)
        """
        # Mock forecast data
        forecast = []
        for i in range(days):
            forecast.append({
                "day": i + 1,
                "high": 25 - i,
                "low": 15 - i,
                "conditions": ["Sunny", "Partly cloudy", "Rainy"][i % 3]
            })
        return forecast


# Step 2: Register the agent in the database
def register_weather_agent():
    """Register the WeatherAgent in Percolate's database"""
    
    print("1. Registering WeatherAgent in database...")
    
    # Create a repository for the agent
    repo = p8.repository(WeatherAgent)
    
    # Register the model (creates tables, etc.)
    # The make_discoverable=True flag is crucial - it creates a Function entry
    repo.register(make_discoverable=True)
    
    print("   ✓ WeatherAgent registered successfully")
    print(f"   ✓ Full name: {WeatherAgent.get_model_full_name()}")
    

# Step 3: Demonstrate discoverability
def demonstrate_discoverability():
    """Show how the agent is now discoverable as a function"""
    
    print("\n2. Checking agent discoverability...")
    
    # The agent is now available as a function
    # When make_discoverable=True is used, a Function entry is created with:
    # - name: {namespace}_{model}_run (e.g., examples_WeatherAgent_run)
    # - proxy_uri: p8agent/{namespace}.{model} (e.g., p8agent/examples.WeatherAgent)
    
    # Search for functions related to weather
    functions = p8.repository(Function).search("weather")
    
    print(f"   ✓ Found {len(functions)} weather-related functions:")
    for func in functions:
        print(f"     - {func['name']}: {func['description'][:100]}...")
    
    # Get the specific function for our agent
    agent_function = p8.repository(Function).select(name="examples_WeatherAgent_run")
    if agent_function:
        func = agent_function[0]
        print(f"\n   ✓ WeatherAgent function details:")
        print(f"     - Name: {func['name']}")
        print(f"     - Proxy URI: {func['proxy_uri']}")
        print(f"     - Function spec: {func['function_spec']}")


# Step 4: Use the agent via different methods
def use_weather_agent():
    """Demonstrate different ways to use the agent"""
    
    print("\n3. Using the WeatherAgent...")
    
    # Method 1: Direct usage as an Agent
    print("\n   a) Direct agent usage:")
    weather_agent = p8.Agent(WeatherAgent)
    result = weather_agent.run("What's the weather like in London?")
    print(f"      Result: {result}")
    
    # Method 2: Load by name (after it's been saved)
    print("\n   b) Loading agent by name:")
    loaded_agent = Agent.load("examples.WeatherAgent")
    print(f"      ✓ Loaded: {loaded_agent.get_model_full_name()}")
    
    # Method 3: Use as a discoverable function via proxy
    print("\n   c) Using as a discoverable function:")
    # Get the function entry
    func_records = p8.repository(Function).select(name="examples_WeatherAgent_run")
    if func_records:
        func = Function(**func_records[0])
        # The function can be called via its proxy
        result = func(question="What's the forecast for Paris?")
        print(f"      Result: {result}")


# Step 5: Advanced usage - Creating dynamic agents
def create_dynamic_agent():
    """Show how to create agents dynamically and make them discoverable"""
    
    print("\n4. Creating a dynamic agent...")
    
    # Create a dynamic model using AbstractModel.create_model
    DynamicNewsAgent = AbstractModel.create_model(
        name="NewsAgent",
        namespace="dynamic",
        description="An agent that provides news and current events information",
        functions={
            "get_top_headlines": "Get today's top news headlines",
            "search_news": "Search for news on a specific topic"
        },
        fields={
            "category": (str, Field(default="general", description="News category")),
            "country": (str, Field(default="us", description="Country code"))
        }
    )
    
    # Register the dynamic agent
    repo = p8.repository(DynamicNewsAgent)
    repo.register(make_discoverable=True)
    
    print(f"   ✓ Dynamic NewsAgent created: {DynamicNewsAgent.get_model_full_name()}")
    
    # Save an instance of the agent metadata using the Agent model
    agent_record = Agent.from_abstract_model(DynamicNewsAgent)
    p8.repository(Agent).update_records(agent_record)
    
    print("   ✓ NewsAgent metadata saved to database")


# Step 6: Query and discover all agents
def discover_all_agents():
    """Show how to discover all available agents"""
    
    print("\n5. Discovering all available agents...")
    
    # Get all agents
    all_agents = p8.repository(Agent).select()
    print(f"   ✓ Found {len(all_agents)} total agents")
    
    # Get all discoverable functions (agents that can be called)
    agent_functions = p8.repository(Function).select()
    discoverable = [f for f in agent_functions if 'p8agent/' in f.get('proxy_uri', '')]
    
    print(f"   ✓ Found {len(discoverable)} discoverable agent functions:")
    for func in discoverable:
        print(f"     - {func['name']} -> {func['proxy_uri']}")


# Main execution
if __name__ == "__main__":
    print("=== Percolate Agent Discoverability Example ===\n")
    
    try:
        # Register the weather agent
        register_weather_agent()
        
        # Show discoverability
        demonstrate_discoverability()
        
        # Use the agent
        use_weather_agent()
        
        # Create dynamic agents
        create_dynamic_agent()
        
        # Discover all agents
        discover_all_agents()
        
        print("\n✅ Example completed successfully!")
        
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()