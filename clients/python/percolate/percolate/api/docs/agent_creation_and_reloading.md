# Agent Creation and Reloading Documentation

## Overview

This document describes the complete lifecycle of agent creation, persistence, and dynamic reloading in the Percolate system. The architecture supports creating agents via API, persisting them with full metadata, loading them dynamically as executable models, and making them discoverable by other agents.

## Agent Creation Flow

### 1. API Endpoint

**POST /entities/**

The agent creation starts with a POST request to the entities endpoint:

```python
# percolate/api/routes/entities/router.py
@router.post("/")
async def create_entity(
    entity_data: dict,
    make_discoverable: bool = False,
    identity: SessionContext = Depends(hybrid_auth),
    pg: PostgresService = Depends(get_postgres)
)
```

**Key Parameters:**
- `entity_data`: The agent definition including name, schema, functions, metadata
- `make_discoverable`: Whether to register the agent as a discoverable Function
- `identity`: Authentication context from hybrid_auth

### 2. Agent Model Structure

Agents are defined using the `Agent` class from `percolate.models.p8.types`:

```python
class Agent(AbstractModel):
    name: str
    category: str
    description: Optional[str]
    spec: dict  # JSON schema defining the agent's data model
    functions: Optional[dict] = None  # Callable functions
    metadata: Optional[dict] = None  # Including on_load queries
```

**Example Agent Definition:**

```json
{
  "entity_type": "Agent",
  "name": "CustomerServiceAgent",
  "namespace": "support",
  "category": "customer_support",
  "description": "Handles customer inquiries and support tickets",
  "spec": {
    "type": "object",
    "properties": {
      "customer_id": {"type": "string"},
      "inquiry_type": {"type": "string"},
      "priority": {"type": "integer", "minimum": 1, "maximum": 5}
    },
    "required": ["customer_id", "inquiry_type"]
  },
  "functions": {
    "resolve_ticket": {
      "description": "Resolve a customer support ticket",
      "parameters": {
        "ticket_id": {"type": "string"},
        "resolution": {"type": "string"}
      }
    }
  },
  "metadata": {
    "on_load": [
      "SELECT * FROM support_templates WHERE active = true"
    ],
    "version": "1.0.0"
  }
}
```

### 3. Creation Process

1. **Namespace Assignment**: If no namespace is provided, defaults to 'public'
2. **Entity Creation**: The agent is created and stored in PostgreSQL
3. **Discoverability**: If `make_discoverable=true`, a Function entity is created:
   - Function name: `{namespace}_{agent_name}_run`
   - Proxy URI: `p8agent/{namespace.name}`
   - Makes agent searchable via semantic search

## Agent Persistence

Agents are persisted in PostgreSQL with the following structure:

```sql
-- Agents are stored in the entities table
INSERT INTO entities (
    id, entity_type, name, namespace, category, 
    description, spec, functions, metadata, created_by
) VALUES (
    gen_random_uuid(), 'Agent', 'CustomerServiceAgent', 'support',
    'customer_support', 'Handles customer inquiries...',
    '{"type": "object", ...}'::jsonb,
    '{"resolve_ticket": {...}}'::jsonb,
    '{"on_load": [...], "version": "1.0.0"}'::jsonb,
    :user_id
);
```

## Dynamic Agent Loading

### 1. Memory Proxy Loading

The memory proxy loads agents through `percolate.interface.try_load_model()`:

```python
def try_load_model(
    model_name: str,
    custom_loader: Optional[Callable] = None,
    allow_abstract: bool = False
) -> type[AbstractModel]:
```

**Loading Order:**
1. Try custom loader if provided
2. Try loading from percolate core models
3. Try `Agent.load()` from database
4. Create abstract model if `allow_abstract=True`

### 2. Agent.load() Method

The `Agent.load()` method reconstructs a full agent from database:

```python
@classmethod
def load(cls, name: str, pg: PostgresService = None) -> type[AbstractModel]:
    # 1. Query agent from database
    agent_data = pg.get_entity(name, entity_type="Agent")
    
    # 2. Create Agent instance
    agent = cls(**agent_data)
    
    # 3. Create dynamic model from agent spec
    return agent._create_model_from_data(agent_data)
```

### 3. Dynamic Model Creation

The `_create_model_from_data()` method creates a Pydantic model dynamically:

```python
def _create_model_from_data(self, data: dict) -> type[AbstractModel]:
    # 1. Parse schema from spec
    schema = self.spec
    
    # 2. Create field definitions
    fields = {}
    for prop_name, prop_def in schema.get("properties", {}).items():
        field_type = map_json_type_to_python(prop_def["type"])
        fields[prop_name] = (field_type, Field(...))
    
    # 3. Add agent metadata
    fields["agent_id"] = (str, Field(default=self.id))
    
    # 4. Create dynamic model class
    model_class = create_model(
        self.name,
        __base__=(AbstractModel,),
        **fields
    )
    
    # 5. Attach functions if any
    if self.functions:
        for func_name, func_def in self.functions.items():
            setattr(model_class, func_name, create_function(func_def))
    
    return model_class
```

## Agent Execution

Agents are executed through the `ModelRunner` service:

```python
runner = ModelRunner(
    model=loaded_agent_class,
    pg=postgres_service,
    llm_configs=llm_configs
)

# Execute with message stack
result = await runner.run(
    message_stack=messages,
    stream=False
)
```

## Test Scenarios

### 1. Agent Creation Test

```python
async def test_create_agent():
    # 1. Create agent via API
    response = await client.post("/entities/", json={
        "entity_type": "Agent",
        "name": "TestAgent",
        "namespace": "test",
        "spec": {
            "type": "object",
            "properties": {
                "test_field": {"type": "string"}
            }
        }
    })
    
    assert response.status_code == 200
    agent_data = response.json()
    assert agent_data["name"] == "TestAgent"
    assert agent_data["namespace"] == "test"
```

### 2. Agent Reloading Test

```python
async def test_reload_agent():
    # 1. Create agent
    agent_id = create_test_agent()
    
    # 2. Load agent dynamically
    AgentModel = try_load_model("test.TestAgent")
    
    # 3. Verify it's a proper Pydantic model
    assert issubclass(AgentModel, AbstractModel)
    
    # 4. Create instance and validate
    instance = AgentModel(test_field="hello")
    assert instance.test_field == "hello"
    assert instance.agent_id == agent_id
```

### 3. Discoverable Agent Test

```python
async def test_discoverable_agent():
    # 1. Create discoverable agent
    response = await client.post(
        "/entities/?make_discoverable=true",
        json=agent_data
    )
    
    # 2. Search for agent function
    functions = await search_functions("TestAgent")
    
    # 3. Verify function was created
    assert any(f.name == "test_TestAgent_run" for f in functions)
```

### 4. Agent with Functions Test

```python
async def test_agent_with_functions():
    # 1. Create agent with functions
    agent_data = {
        "entity_type": "Agent",
        "name": "FunctionAgent",
        "functions": {
            "calculate": {
                "description": "Calculate something",
                "code": "return x + y"
            }
        }
    }
    
    # 2. Load and execute
    AgentModel = try_load_model("public.FunctionAgent")
    instance = AgentModel()
    
    # 3. Verify function exists
    assert hasattr(instance, "calculate")
    result = instance.calculate(x=1, y=2)
    assert result == 3
```

## Memory Proxy Integration

The memory proxy should handle dynamic agent loading seamlessly:

1. **Registration**: Agents are automatically registered when created
2. **Discovery**: Agents can be discovered via semantic search if marked discoverable
3. **Loading**: The `try_load_model()` function handles all loading scenarios
4. **Caching**: Loaded agent models should be cached for performance
5. **Reloading**: Changes to agents should trigger reload on next access

## Security Considerations

1. **Authentication**: All agent creation requires authentication
2. **Namespace Isolation**: Agents are isolated by namespace
3. **RLS Policies**: Row-level security ensures users only see their agents
4. **Function Execution**: Agent functions run in controlled environment
5. **Resource Limits**: Agents should have configurable resource limits

## Best Practices

1. **Versioning**: Include version in agent metadata
2. **Schema Validation**: Always validate agent schemas before creation
3. **Function Safety**: Sanitize and validate function definitions
4. **Error Handling**: Gracefully handle loading failures
5. **Documentation**: Document agent capabilities in description
6. **Testing**: Test both creation and reloading paths
7. **Monitoring**: Log agent creation and execution metrics