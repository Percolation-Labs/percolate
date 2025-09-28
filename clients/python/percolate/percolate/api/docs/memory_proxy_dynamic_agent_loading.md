# Memory Proxy Dynamic Agent Loading

## Overview

The Memory Proxy is a critical component that enables dynamic loading of agents created at runtime. This document details how the memory proxy discovers, loads, caches, and manages dynamically created agents in the Percolate system.

## Architecture

### Key Components

1. **MemoryProxy**: Central orchestrator for model loading and caching
2. **try_load_model()**: Universal model loading function in `percolate.interface`
3. **Agent.load()**: Class method for loading agents from database
4. **Model Cache**: In-memory cache for loaded agent models
5. **PostgresService**: Database interface for agent persistence

## Dynamic Loading Flow

### 1. Model Resolution

When a model is requested through `try_load_model()`, the following resolution order is followed:

```python
def try_load_model(
    model_name: str,
    custom_loader: Optional[Callable] = None,
    allow_abstract: bool = False
) -> type[AbstractModel]:
    
    # 1. Custom loader (highest priority)
    if custom_loader:
        try:
            return custom_loader(model_name)
        except: pass
    
    # 2. Core percolate models
    try:
        return import_model_from_percolate(model_name)
    except: pass
    
    # 3. Dynamic agent loading
    try:
        return Agent.load(model_name)
    except: pass
    
    # 4. Abstract model fallback
    if allow_abstract:
        return create_abstract_model(model_name)
    
    raise ModelNotFoundError(f"Could not load model: {model_name}")
```

### 2. Agent Loading Process

The `Agent.load()` method performs the following steps:

```python
@classmethod
def load(cls, name: str, pg: PostgresService = None) -> type[AbstractModel]:
    # Parse namespace and name
    namespace, agent_name = parse_model_name(name)
    
    # Query database
    agent_data = pg.get_entity(
        name=agent_name,
        namespace=namespace,
        entity_type="Agent"
    )
    
    if not agent_data:
        raise AgentNotFoundError(f"Agent {name} not found")
    
    # Create Agent instance
    agent = cls(**agent_data)
    
    # Generate dynamic model
    return agent._create_model_from_data(agent_data)
```

### 3. Dynamic Model Generation

The `_create_model_from_data()` method creates a Pydantic model dynamically:

```python
def _create_model_from_data(self, data: dict) -> type[AbstractModel]:
    # Extract schema
    schema = self.spec
    properties = schema.get("properties", {})
    required = schema.get("required", [])
    
    # Build field definitions
    fields = {}
    for prop_name, prop_def in properties.items():
        python_type = map_json_schema_to_python(prop_def)
        default = ... if prop_name in required else None
        fields[prop_name] = (python_type, Field(default=default))
    
    # Add agent metadata
    fields["agent_id"] = (str, Field(default=self.id))
    
    # Create model class
    DynamicModel = create_model(
        self.name,
        __base__=(AbstractModel,),
        **fields
    )
    
    # Attach functions
    if self.functions:
        attach_functions_to_model(DynamicModel, self.functions)
    
    # Store metadata
    DynamicModel.__agent_metadata__ = {
        "id": self.id,
        "namespace": self.namespace,
        "version": self.metadata.get("version", "1.0.0")
    }
    
    return DynamicModel
```

## Memory Proxy Implementation

### 1. Basic Memory Proxy

```python
class MemoryProxy:
    def __init__(self, postgres_service: PostgresService):
        self.pg = postgres_service
        self._model_cache = {}
        self._cache_ttl = 300  # 5 minutes
        self._cache_timestamps = {}
    
    def load_model(self, model_name: str) -> type[AbstractModel]:
        """Load a model with caching support"""
        # Check cache first
        if self._is_cached_valid(model_name):
            return self._model_cache[model_name]
        
        # Load model
        model = try_load_model(
            model_name,
            custom_loader=lambda name: Agent.load(name, self.pg)
        )
        
        # Cache the model
        self._cache_model(model_name, model)
        
        return model
    
    def _is_cached_valid(self, model_name: str) -> bool:
        """Check if cached model is still valid"""
        if model_name not in self._model_cache:
            return False
        
        timestamp = self._cache_timestamps.get(model_name, 0)
        return (time.time() - timestamp) < self._cache_ttl
    
    def _cache_model(self, model_name: str, model: type):
        """Cache a loaded model"""
        self._model_cache[model_name] = model
        self._cache_timestamps[model_name] = time.time()
    
    def invalidate_cache(self, model_name: str = None):
        """Invalidate cache for specific model or all models"""
        if model_name:
            self._model_cache.pop(model_name, None)
            self._cache_timestamps.pop(model_name, None)
        else:
            self._model_cache.clear()
            self._cache_timestamps.clear()
```

### 2. Advanced Memory Proxy with Features

```python
class AdvancedMemoryProxy(MemoryProxy):
    def __init__(self, postgres_service: PostgresService):
        super().__init__(postgres_service)
        self._loading_locks = {}
        self._preload_queue = asyncio.Queue()
        self._model_registry = {}
    
    async def load_model_async(self, model_name: str) -> type[AbstractModel]:
        """Async model loading with concurrency control"""
        # Prevent duplicate loading
        if model_name in self._loading_locks:
            async with self._loading_locks[model_name]:
                return self._model_cache.get(model_name)
        
        # Create lock for this model
        self._loading_locks[model_name] = asyncio.Lock()
        
        try:
            async with self._loading_locks[model_name]:
                # Double-check cache
                if self._is_cached_valid(model_name):
                    return self._model_cache[model_name]
                
                # Load in executor to avoid blocking
                loop = asyncio.get_event_loop()
                model = await loop.run_in_executor(
                    None,
                    self.load_model,
                    model_name
                )
                
                return model
        finally:
            # Clean up lock
            self._loading_locks.pop(model_name, None)
    
    def register_model(self, model_class: type[AbstractModel]):
        """Register a model for discovery"""
        model_name = f"{model_class.__module__}.{model_class.__name__}"
        self._model_registry[model_name] = model_class
    
    async def preload_agents(self, namespace: str = None):
        """Preload all agents in a namespace"""
        query = """
        SELECT namespace || '.' || name as full_name
        FROM entities
        WHERE entity_type = 'Agent'
        """
        params = {}
        
        if namespace:
            query += " AND namespace = :namespace"
            params["namespace"] = namespace
        
        agents = self.pg.run_query_get_list(query, params)
        
        # Load all agents concurrently
        tasks = [
            self.load_model_async(agent["full_name"])
            for agent in agents
        ]
        
        await asyncio.gather(*tasks, return_exceptions=True)
    
    def get_loaded_models(self) -> Dict[str, type[AbstractModel]]:
        """Get all currently loaded models"""
        return {
            name: model
            for name, model in self._model_cache.items()
            if self._is_cached_valid(name)
        }
```

### 3. Memory Proxy with Hot Reloading

```python
class HotReloadMemoryProxy(AdvancedMemoryProxy):
    def __init__(self, postgres_service: PostgresService):
        super().__init__(postgres_service)
        self._version_cache = {}
        self._reload_callbacks = defaultdict(list)
    
    def check_for_updates(self, model_name: str) -> bool:
        """Check if model has been updated in database"""
        current_version = self._get_model_version(model_name)
        cached_version = self._version_cache.get(model_name)
        
        return current_version != cached_version
    
    def _get_model_version(self, model_name: str) -> str:
        """Get current version of model from database"""
        namespace, name = model_name.split(".", 1)
        
        result = self.pg.run_query_get_list(
            """
            SELECT metadata->>'version' as version,
                   updated_at
            FROM entities
            WHERE entity_type = 'Agent'
              AND namespace = :namespace
              AND name = :name
            """,
            {"namespace": namespace, "name": name}
        )
        
        if result:
            # Use version + updated timestamp as version key
            return f"{result[0]['version']}_{result[0]['updated_at']}"
        
        return None
    
    def load_model(self, model_name: str) -> type[AbstractModel]:
        """Load model with version checking"""
        # Check if update available
        if model_name in self._model_cache and self.check_for_updates(model_name):
            self.invalidate_cache(model_name)
            self._trigger_reload_callbacks(model_name)
        
        # Load model
        model = super().load_model(model_name)
        
        # Cache version
        self._version_cache[model_name] = self._get_model_version(model_name)
        
        return model
    
    def on_model_reload(self, model_name: str, callback: Callable):
        """Register callback for model reload events"""
        self._reload_callbacks[model_name].append(callback)
    
    def _trigger_reload_callbacks(self, model_name: str):
        """Trigger callbacks when model is reloaded"""
        for callback in self._reload_callbacks[model_name]:
            try:
                callback(model_name)
            except Exception as e:
                logger.error(f"Reload callback failed: {e}")
```

## Integration Examples

### 1. Basic Usage

```python
from percolate.memory import MemoryProxy
from percolate.services import PostgresService

# Initialize
pg = PostgresService()
memory_proxy = MemoryProxy(pg)

# Load agent
CustomerAgent = memory_proxy.load_model("support.CustomerServiceAgent")

# Create instance
agent_instance = CustomerAgent(
    customer_id="12345",
    inquiry_type="billing"
)

# Use in ModelRunner
from percolate.services import ModelRunner

runner = ModelRunner(
    model=CustomerAgent,
    pg=pg,
    llm_configs={"model": "claude-3"}
)

result = await runner.run(message_stack=[...])
```

### 2. Async Loading

```python
# Initialize async proxy
memory_proxy = AdvancedMemoryProxy(pg)

# Preload namespace
await memory_proxy.preload_agents("support")

# Load specific agent
CustomerAgent = await memory_proxy.load_model_async("support.CustomerServiceAgent")
```

### 3. Hot Reload Setup

```python
# Initialize with hot reload
memory_proxy = HotReloadMemoryProxy(pg)

# Register reload callback
def on_agent_reload(model_name: str):
    print(f"Agent {model_name} was reloaded")
    # Reinitialize dependent services
    
memory_proxy.on_model_reload("support.CustomerServiceAgent", on_agent_reload)

# Model will auto-reload on next access if updated
CustomerAgent = memory_proxy.load_model("support.CustomerServiceAgent")
```

## Caching Strategies

### 1. TTL-Based Caching
```python
# Short TTL for frequently updated agents
memory_proxy._cache_ttl = 60  # 1 minute

# Long TTL for stable agents
memory_proxy._cache_ttl = 3600  # 1 hour
```

### 2. LRU Caching
```python
from functools import lru_cache

class LRUMemoryProxy(MemoryProxy):
    @lru_cache(maxsize=100)
    def load_model(self, model_name: str) -> type[AbstractModel]:
        return super().load_model(model_name)
```

### 3. Selective Caching
```python
class SelectiveMemoryProxy(MemoryProxy):
    def __init__(self, postgres_service: PostgresService):
        super().__init__(postgres_service)
        self._cache_rules = {
            "public.*": 3600,  # Public agents cached for 1 hour
            "private.*": 60,   # Private agents cached for 1 minute
            "system.*": None   # System agents never cached
        }
```

## Error Handling

### 1. Loading Failures

```python
try:
    model = memory_proxy.load_model("namespace.AgentName")
except AgentNotFoundError:
    # Agent doesn't exist
    logger.error("Agent not found")
except SchemaValidationError:
    # Invalid agent schema
    logger.error("Agent schema is invalid")
except Exception as e:
    # Other loading errors
    logger.error(f"Failed to load agent: {e}")
```

### 2. Graceful Degradation

```python
def load_with_fallback(memory_proxy, primary_name: str, fallback_name: str):
    """Load agent with fallback option"""
    try:
        return memory_proxy.load_model(primary_name)
    except Exception:
        logger.warning(f"Failed to load {primary_name}, using fallback")
        return memory_proxy.load_model(fallback_name)
```

## Performance Considerations

### 1. Batch Loading
```python
async def batch_load_agents(memory_proxy, agent_names: List[str]):
    """Load multiple agents efficiently"""
    tasks = [
        memory_proxy.load_model_async(name)
        for name in agent_names
    ]
    return await asyncio.gather(*tasks)
```

### 2. Lazy Loading
```python
class LazyLoadProxy:
    def __init__(self, memory_proxy, model_name):
        self._memory_proxy = memory_proxy
        self._model_name = model_name
        self._model = None
    
    def __getattr__(self, name):
        if self._model is None:
            self._model = self._memory_proxy.load_model(self._model_name)
        return getattr(self._model, name)
```

### 3. Connection Pooling
```python
# Use connection pool for database queries
pg_pool = PostgresService(pool_size=10)
memory_proxy = MemoryProxy(pg_pool)
```

## Monitoring and Debugging

### 1. Cache Statistics
```python
class MonitoredMemoryProxy(MemoryProxy):
    def __init__(self, postgres_service: PostgresService):
        super().__init__(postgres_service)
        self._cache_hits = 0
        self._cache_misses = 0
    
    def get_cache_stats(self):
        total = self._cache_hits + self._cache_misses
        hit_rate = self._cache_hits / total if total > 0 else 0
        
        return {
            "hits": self._cache_hits,
            "misses": self._cache_misses,
            "hit_rate": hit_rate,
            "cached_models": len(self._model_cache)
        }
```

### 2. Debug Logging
```python
import logging

logger = logging.getLogger("percolate.memory_proxy")

class DebugMemoryProxy(MemoryProxy):
    def load_model(self, model_name: str) -> type[AbstractModel]:
        logger.debug(f"Loading model: {model_name}")
        start_time = time.time()
        
        try:
            model = super().load_model(model_name)
            duration = time.time() - start_time
            logger.info(f"Loaded {model_name} in {duration:.2f}s")
            return model
        except Exception as e:
            logger.error(f"Failed to load {model_name}: {e}")
            raise
```

## Best Practices

1. **Cache Warming**: Preload frequently used agents on startup
2. **Version Control**: Include version in agent metadata
3. **Namespace Organization**: Use consistent namespace conventions
4. **Error Recovery**: Implement retry logic for transient failures
5. **Security**: Validate agent schemas before loading
6. **Performance**: Monitor cache hit rates and adjust TTL
7. **Testing**: Mock memory proxy in unit tests
8. **Documentation**: Document agent schemas and capabilities