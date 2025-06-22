# Agent Discoverability in Percolate

This guide explains how to create agents/models in Percolate and make them discoverable so they can be found and used by other agents or systems.

## Overview

In Percolate, agents are AI-powered models that can perform specific tasks. Making an agent "discoverable" means:
1. It can be found via semantic search
2. It can be called as a function by other agents
3. It appears in the system's function registry

## Key Concepts

### 1. Agent vs Model
- **Model**: A Pydantic model class that defines the schema and behavior
- **Agent**: A model instance that can process queries and execute functions

### 2. Function Registry
When an agent is made discoverable, it's registered as a `Function` with:
- A searchable description
- A callable interface
- A proxy URI for remote execution

### 3. The `make_discoverable` Flag
The `make_discoverable=True` parameter in `repository.register()` automatically:
- Creates a `Function` entry for the agent
- Sets up the proxy routing
- Makes it searchable

## Step-by-Step Guide

### Step 1: Define Your Agent Model

```python
from percolate.models import AbstractModel
from pydantic import Field

class MyCustomAgent(AbstractModel):
    """Agent description that will be searchable"""
    
    model_config = {
        'name': 'MyCustomAgent',
        'namespace': 'custom',
        'description': 'Detailed description for search',
        'functions': {
            'process': 'Process data according to agent logic',
            'analyze': 'Analyze input and provide insights'
        }
    }
    
    # Define fields
    input_data: str = Field(description="Input to process")
    
    # Define methods that can be called
    @classmethod
    def process(cls, data: str) -> dict:
        """Process the input data"""
        return {"processed": data.upper()}
```

### Step 2: Register the Agent

```python
import percolate as p8

# Create repository
repo = p8.repository(MyCustomAgent)

# Register with discoverability enabled
repo.register(make_discoverable=True)
```

### Step 3: How It's Stored

When you register with `make_discoverable=True`:

1. **Agent Table Entry**: Metadata about your agent is stored
2. **Function Table Entry**: A callable function is created with:
   - Name: `{namespace}_{agent_name}_run`
   - Proxy URI: `p8agent/{namespace}.{agent_name}`
   - Description: From your agent's docstring

### Step 4: Discovery Methods

#### Search for Agents
```python
# Search by description
functions = p8.repository(Function).search("custom data processing")

# Get specific function
agent_func = p8.repository(Function).select(name="custom_MyCustomAgent_run")
```

#### Load and Use
```python
# Method 1: Load by name
from percolate.models.p8.types import Agent
loaded = Agent.load("custom.MyCustomAgent")

# Method 2: Use via Agent interface
agent = p8.Agent(MyCustomAgent)
result = agent.run("Process this data")

# Method 3: Call as function (if you have the Function object)
func = Function(**agent_func[0])
result = func(question="Process my data")
```

## How Function.from_entity Works

The `Function.from_entity()` method converts an agent/model into a callable function:

```python
# This happens internally when make_discoverable=True
function = Function.from_entity(MyCustomAgent)

# The function has:
# - name: "custom_MyCustomAgent_run"
# - description: Combines agent description and available functions
# - function_spec: OpenAI-compatible function schema
# - proxy_uri: "p8agent/custom.MyCustomAgent"
```

## Advanced Usage

### Dynamic Agent Creation
```python
# Create agent dynamically
DynamicAgent = AbstractModel.create_model(
    name="DynamicHelper",
    namespace="dynamic",
    description="A dynamically created helper",
    functions={"help": "Provide assistance"},
    fields={
        "query": (str, Field(description="User query"))
    }
)

# Register and make discoverable
p8.repository(DynamicAgent).register(make_discoverable=True)
```

### Agent Metadata Storage
```python
# Save additional metadata
from percolate.models.p8.types import Agent

agent_metadata = Agent.from_abstract_model(MyCustomAgent)
p8.repository(Agent).update_records(agent_metadata)
```

## Best Practices

1. **Clear Descriptions**: Write detailed docstrings - they're used for search
2. **Meaningful Names**: Use descriptive names for namespace and model
3. **Function Documentation**: Document each function in the model_config
4. **Unique Namespaces**: Use unique namespaces to avoid collisions
5. **Test Discoverability**: Always verify your agent can be found via search

## Common Patterns

### Pattern 1: Specialized Agents
Create agents for specific domains:
```python
class FinanceAgent(AbstractModel):
    """Handles financial calculations and analysis"""
    # ... implementation

class DataAnalysisAgent(AbstractModel):
    """Performs statistical analysis on datasets"""
    # ... implementation
```

### Pattern 2: Agent Composition
Agents can discover and use other agents:
```python
class OrchestratorAgent(AbstractModel):
    """Coordinates multiple specialized agents"""
    
    def process(self, task: str):
        # Discover relevant agents
        agents = p8.repository(Function).search(task)
        # Use them to complete the task
```

### Pattern 3: API Integration
Make external APIs discoverable:
```python
class WeatherAPIAgent(AbstractModel):
    """Wraps weather API as discoverable agent"""
    
    @classmethod
    def get_weather(cls, location: str):
        # Call external API
        return weather_data
```

## Troubleshooting

### Agent Not Found
- Check the namespace and name are correct
- Verify `make_discoverable=True` was used
- Ensure registration completed successfully

### Function Not Callable
- Verify the proxy_uri is correct
- Check that the agent model is loadable
- Ensure all dependencies are available

### Search Not Working
- Check the description field is populated
- Verify embeddings are generated (may take time)
- Use more specific search terms

## Example Output

When you run the example script, you'll see:
```
1. Registering WeatherAgent in database...
   ✓ WeatherAgent registered successfully
   ✓ Full name: examples.WeatherAgent

2. Checking agent discoverability...
   ✓ Found 1 weather-related functions:
     - examples_WeatherAgent_run: I am a weather information agent...

3. Using the WeatherAgent...
   a) Direct agent usage:
      Result: {"weather": "sunny", "temp": 22}
```

This confirms your agent is properly registered and discoverable!