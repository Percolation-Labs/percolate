# Embedded Percolate

This document outlines the implementation of Embedded Percolate using DuckDB (for SQL tables with vector search) and KuzuDB (for graph data).

> **IMPORTANT NOTE:** We are freezing notebook updates because they are expensive to maintain. Future improvements will focus on the core library implementation. The examples in the notebooks should still work with the latest code, but they may not showcase the most efficient patterns like batch embedding processing.

## Overview

Embedded Percolate provides a lightweight, file-based alternative to the PostgreSQL implementation. It maintains compatibility with the existing Pydantic model-based approach while operating locally without requiring a server.

## Complete Flow

The embedded Percolate implementation provides a complete end-to-end flow with the following capabilities:

1. **Create tables from models**: Automatically create SQL tables with embedding support based on Pydantic models
2. **Add and update records**: Insert and update records with idempotent operations
3. **Build embeddings**: Add vector embeddings for semantic search
4. **Create graph entities**: Add entities and relationships to the graph database
5. **Query with both strategies**: Search data using both SQL and graph operations

### Running the Flow

To quickly test the entire embedded flow, you can run the included example script:

```bash
python -m percolate.services.embedded.run_flow
```

This script will:
- Create temporary database files
- Register a Document model with embedding support
- Add and update records to demonstrate idempotence
- Add embeddings for semantic search
- Create graph entities and relationships
- Perform lookups by ID, name, and test neighbor relationships

The output will show the success of each step and display the created database paths.

### Flow Implementation Example

Here's a simplified example of how to implement the complete flow in your code:

```python
from pydantic import BaseModel, Field
from percolate.utils import make_uuid
from percolate.services.embedded import DuckDBService, KuzuDBService

# 1. Define your model
class Document(BaseModel):
    model_config = {'namespace': 'docs'}
    
    id: str = Field(description="Document ID")
    title: str = Field(description="Document title")
    content: str = Field(description="Document content", 
                         json_schema_extra={'embedding_provider': 'default'})
    author: str = Field(description="Document author")
    tags: list[str] = Field(default_factory=list)

# 2. Initialize and register the model
doc_service = DuckDBService(Document)
doc_service.register()

# 3. Add records
doc = Document(
    id=make_uuid("doc1"),
    title="Introduction to Embeddings",
    content="Embeddings are vector representations of data...",
    author="AI Researcher",
    tags=["embeddings", "vectors", "ML"]
)
doc_service.update_records(doc)

# 4. Update records (idempotent)
doc.content += " They enable similarity search and more."
doc_service.update_records(doc)

# 5. Add embeddings
doc_service.add_embeddings(
    records=[{"id": doc.id, "content": doc.content}],
    embedding_field="content"
)

# 6. Search by content
results = doc_service.execute(
    "SELECT * FROM docs.\"Document\" WHERE content LIKE '%embeddings%'"
)

# 7. Add to graph database
kuzu_service = KuzuDBService()
kuzu_service.add_entities("docs.Document", [
    {"id": doc.id, "name": doc.title}
])

# 8. Find entity by name
entity = kuzu_service.find_entity_by_name("Introduction to Embeddings")
```

## PyIceberg Integration

The DuckDBService integrates with [PyIceberg](https://py.iceberg.apache.org/) for advanced table management, but this integration is **optional** and disabled by default.

### Enabling PyIceberg

To use PyIceberg with Percolate:

1. Install the optional dependency:
   ```bash
   poetry install --with iceberg
   ```

2. Set the environment variable to enable PyIceberg:
   ```bash
   export PERCOLATE_USE_PYICEBERG=1
   ```

When PyIceberg is enabled, DuckDBService will:
- Create and manage an Iceberg catalog for tables
- Use Iceberg's advanced table features like schema evolution 
- Enable more efficient upsert operations using merge capabilities

If PyIceberg is not available or not enabled, DuckDBService will automatically fall back to standard SQL operations.

## Usage Example

Here's how to use the embedded Percolate services with an existing entity type (Agent):

```python
from percolate.models.p8 import Agent
from percolate.services.embedded import DuckDBService, KuzuDBService
import uuid

# Initialize DuckDB service with default path (~/.percolate/db)
duck_service = DuckDBService(Agent)

# Register the Agent model schema in DuckDB
duck_service.register()

# Create sample agent entities with deterministic IDs (based on name)
from percolate.utils import make_uuid

agents = [
    Agent(
        id=make_uuid({"name": "SearchAgent"}),  # Deterministic ID based on name
        name="SearchAgent",
        category="Research",
        description="Agent that performs web searches and summarizes results",
        spec={"capabilities": ["search", "summarize"]},
        functions={"search_web": "Performs web search using search APIs"}
    ),
    Agent(
        id=make_uuid({"name": "WriterAgent"}),  # Deterministic ID based on name
        name="WriterAgent",
        category="Content",
        description="Agent that writes and edits content based on prompts",
        spec={"capabilities": ["write", "edit", "proofread"]},
        functions={"generate_content": "Creates content based on prompts"}
    ),
    Agent(
        id=make_uuid({"name": "DataAnalysisAgent"}),  # Deterministic ID based on name
        name="DataAnalysisAgent",
        category="Analytics",
        description="Agent that analyzes data and generates insights",
        spec={"capabilities": ["analyze", "visualize"]},
        functions={"analyze_dataset": "Performs statistical analysis on data"}
    )
]

# Insert agents in batch
duck_service.update_records(agents, batch_size=10)

# Query agents by category
research_agents = duck_service.select(category="Research")
print(f"Found {len(research_agents)} research agents")

# Query agents by substring in description (using LIKE)
analysis_agents = duck_service.execute(
    "SELECT * FROM p8.agent WHERE description LIKE '%analyzes data%'"
)

# Initialize KuzuDB service for graph operations
kuzu_service = KuzuDBService()

# Add entities to graph database
agent_entities = [
    {"id": str(agent.id), "name": agent.name}
    for agent in agents
]
kuzu_service.add_entities("p8.Agent", agent_entities)

# Create relationships between agents
kuzu_service.create_relationship(
    str(agents[0].id),  # SearchAgent
    str(agents[2].id),  # DataAnalysisAgent
    "COLLABORATES_WITH",
    weight=0.8
)

# Find collaborating agents using Cypher query
collaborators = kuzu_service.execute_cypher("""
    MATCH (a:Entity)-[r:Relationship {type: 'COLLABORATES_WITH'}]->(b:Entity)
    RETURN a.name as source, b.name as target, r.weight as strength
""")
```

## Implementation Plan

### 1. DuckDB Service

The `DuckDBService` class follows the same pattern as `PostgresService`:

```python
class DuckDBService:
    def __init__(self, model: BaseModel = None, db_path: str = None):
        self.db_path = db_path or os.path.expanduser("~/.percolate/db")
        self.conn = self._connect()
        self.helper = DuckModelHelper(AbstractModel)
        if model:
            self.model = AbstractModel.Abstracted(ensure_model_not_instance(model))
            self.helper = DuckModelHelper(model)
        else:
            self.model = None
```

Key features:
- Automatic type conversion from Pydantic models to DuckDB types
- Upsert support using PyIceberg's merge operations with Polars dataframes
- Fallback to SQL-based upserts when PyIceberg is not available
- Async index creation after record insertion
- Complete entity lifecycle management (register, update, drop)
- Repository pattern for model-specific operations

### 2. Embedding Support

DuckDB supports vector operations through its VSS extension:

```python
def _setup_extensions(self):
    self.conn.execute("INSTALL vss;")
    self.conn.execute("LOAD vss;")
```

Embedding tables follow the same schema as PostgreSQL:
- Companion tables for entities with embedding fields
- HNSW indexes for efficient vector search
- Similarity search with DuckDB-specific syntax

### 3. KuzuDB Integration

The `KuzuDBService` class handles graph operations:

```python
class KuzuDBService:
    def __init__(self, db_path: str = None):
        self.db_path = db_path or os.path.expanduser("~/.percolate/graph")
        self.conn = kuzu.Connection(self.db_path)
```

Key graph features:
- Add entity nodes with ID and name properties
- Create relationships between entities
- Support for Cypher query execution
- Batch operations for efficient updates

### 4. Async Index Building

For non-blocking index creation:

```python
async def build_indexes(self, entity_name: str, id: uuid.UUID = None):
    """Build indexes for entity asynchronously"""
    # Create semantic index if embedding fields exist
    # Create entity index if name field exists
    # Log index creation status
```

The index building process:
1. Checks if entity has a 'name' field (required for entity index)
2. Checks if entity has fields with embedding attributes
3. Builds appropriate indexes without blocking the main thread
4. Logs completion status and metrics

### 5. Helper Classes

- `DuckModelHelper`: Converts Pydantic models to DuckDB schemas
- `EmbeddingManager`: Handles vector operations and index creation
- `IndexAudit`: Tracks index creation status and metrics

## Implementation Requirements

1. **Type Support**:
   - Maintain compatibility with PostgresService
   - Support all Pydantic types for DuckDB schema generation

2. **Upsert Operations**:
   - PyIceberg integration for DataFrame-based upserts with merge operations
   - Support for batch operations with efficient primary key-based merging
   - Polars DataFrame integration for data transformation
   - SQL-based upsert fallback for compatibility

3. **Indexing**:
   - Automatically detect fields requiring indexes
   - Build indexes asynchronously to avoid blocking
   - Support both semantic (vector) and entity (graph) indexes

4. **Query Support**:
   - Implement the search method that combines:
     - SQL predicate filtering
     - Vector similarity search
     - Graph entity lookups
   - Merge results based on relevance

## Entity Lifecycle Management

The DuckDBService provides complete entity lifecycle management, including registering, updating, and dropping entities:

```python
from percolate.models.p8 import Agent
from percolate.services.embedded import DuckDBService

# Initialize service with a model
agent_repo = DuckDBService(Agent)

# Register the entity (creates tables and PyIceberg catalogs)
agent_repo.register()

# Add records
# ... (code to create and insert records)

# When you're done with the entity, you can drop it completely
result = agent_repo.drop_entity()
if result["success"]:
    print("Entity dropped successfully")
else:
    print(f"Some issues occurred: {result['errors']}")

# You can register it again if needed
agent_repo.register()
```

The `drop_entity` method:
- Removes the entity from PyIceberg catalogs
- Drops the main entity table
- Drops associated embedding tables
- Cleans up any graph database entries (when implemented)

## Example: Creating and Querying a Complex Entity

Here's a complete example of working with a more complex entity type:

### PyIceberg Upsert Example

```python
import polars as pl
from percolate.models.p8 import Agent
from percolate.services.embedded import DuckDBService
import uuid

# Initialize service
service = DuckDBService(Agent)
service.register()

# Create initial agents with deterministic IDs
from percolate.utils import make_uuid

initial_agents = [
    Agent(
        id=make_uuid({"name": "DataAgent"}),  # Deterministic ID based on name
        name="DataAgent",
        category="Analytics",
        description="Processes and analyzes data",
        spec={"capabilities": ["analyze", "transform"]},
        functions={"analyze_data": "Performs data analysis"}
    ),
    Agent(
        id=make_uuid({"name": "ReportAgent"}),  # Deterministic ID based on name
        name="ReportAgent",
        category="Reporting",
        description="Generates reports from data",
        spec={"capabilities": ["report", "visualize"]},
        functions={"generate_report": "Creates reports"}
    )
]

# Insert initial agents
service.update_records(initial_agents)
print(f"Added {len(initial_agents)} initial agents")

# Later, update one agent and add a new one
agent_to_update = initial_agents[0]
agent_to_update.description = "Updated: Processes and analyzes complex datasets"
agent_to_update.spec["capabilities"].append("predict")

new_agent = Agent(
    id=make_uuid({"name": "IntegrationAgent"}),  # Deterministic ID based on name
    name="IntegrationAgent",
    category="Integration",
    description="Connects to external systems",
    spec={"capabilities": ["connect", "sync"]},
    functions={"sync_data": "Synchronizes data with external systems"}
)

# Perform upsert with PyIceberg - this will update the existing agent and add the new one
update_batch = [agent_to_update, new_agent]
service.update_records(update_batch)

# Verify updates
updated_agent = service.select(id=str(agent_to_update.id))[0]
print(f"Updated agent description: {updated_agent['description']}")
print(f"Updated agent capabilities: {updated_agent['spec']}")

# Get all agents
all_agents = service.execute("SELECT name, category FROM p8.agent")
print(f"Total agents after upsert: {len(all_agents)}")
```

Here's a complete example of working with a more complex entity type:

```python
import asyncio
from percolate.models.p8 import ResearchIteration
from percolate.services.embedded import DuckDBService
import uuid

# Initialize service
service = DuckDBService(ResearchIteration)
service.register()

# Create a research iteration with embedded fields and nested structures
research = ResearchIteration(
    id=uuid.uuid4(),
    iteration=1,
    content="Initial research on quantum computing applications",
    conceptual_diagram="""
    graph TD
        A[Quantum Computing] --> B[Algorithms]
        A --> C[Hardware]
        B --> D[Shor's Algorithm]
        B --> E[Grover's Algorithm]
        C --> F[Superconducting Qubits]
        C --> G[Ion Traps]
    """,
    question_set=[
        {
            "query": "What are the most promising quantum algorithms?",
            "concept_keys": ["B", "D", "E"]
        },
        {
            "query": "What are the current limitations of quantum hardware?",
            "concept_keys": ["C", "F", "G"]
        }
    ],
    task_id=uuid.uuid4()
)

# Insert the research iteration
service.update_records(research)

# Query by content substring
results = service.execute(
    "SELECT id, iteration, content FROM p8.researchiteration WHERE content LIKE '%quantum%'"
)
print(f"Found {len(results)} research iterations about quantum computing")

# Update with new questions
research.question_set.append({
    "query": "How do quantum error correction codes work?",
    "concept_keys": ["B", "C"]
})
service.update_records(research)

# Asynchronously build indexes
asyncio.run(service.build_indexes(ResearchIteration.model_config['namespace'] + "." + ResearchIteration.__name__))
```

## Complete flow example

1. WE create a table from a model. PyIceberg catalogs are used so we can upsert. We add the table and its embedding table (check)
2. WE create some records, we insert them twice to make sure upserts work 
3. we add a semantic index (implement the open ai embeddings only for now - always compute embeddings in batch) - a repo.add_embeddings helper can be used to test this or add these in isolation. the same upsert functionality should work here as we have a unique id for each embedding
4. we manually add an entity index in the graph - we can test that we can find entities by name - inserted - the get_entity in duck db should use the graph first to get the entity and then select from matching keys
5. we should test the semantic search -  the repo should have a semantic search helper for isolated testing (later it can be bundled) - if we inserted records and their index, it should be able to search semantically
together these test the entire flow. tables can be registered. WE can manage semantic and graph/entity indexes. We can upsert records and search their indexes

## Implementation and Testing Example

The following example demonstrates the complete flow using the diagnostic helper methods:

```python
import os
import uuid
from percolate.models.p8 import Agent
from percolate.services.embedded import DuckDBService, KuzuDBService

# Step 1: Enable PyIceberg if available (optional)
os.environ["PERCOLATE_USE_PYICEBERG"] = "1"

# Create a temporary DB path for testing
db_path = "/tmp/percolate_test.db"

# Initialize the service with the Agent model
service = DuckDBService(Agent, db_path=db_path)

# Check PyIceberg status before creating tables
print("Initial PyIceberg Status:")
print(service.get_iceberg_status())

# Register the model (creates tables and PyIceberg catalogs)
print("\nRegistering Agent model...")
service.register()

# Check PyIceberg status after registration
print("\nPyIceberg Status After Registration:")
iceberg_status = service.get_iceberg_status()
print(f"Catalog loaded: {iceberg_status.get('catalog_loaded', False)}")
print(f"Namespaces: {iceberg_status.get('namespaces', [])}")
print(f"Tables: {iceberg_status.get('tables', {})}")

# Check table information
print("\nTable Information:")
table_info = service.get_table_info()
print(f"Table exists: {table_info.get('exists', False)}")
if table_info.get('exists'):
    print(f"Schema: {table_info.get('schema')}")
    print(f"Properties: {table_info.get('properties')}")

# Step 2: Create and upsert records
print("\nCreating test agents...")
agents = [
    Agent(
        id=uuid.uuid4(),
        name="SearchAgent",
        category="Research",
        description="Agent that performs web searches and summarizes results",
        spec={"capabilities": ["search", "summarize"]},
        functions={"search_web": "Performs web search using search APIs"}
    ),
    Agent(
        id=uuid.uuid4(),
        name="WriterAgent",
        category="Content",
        description="Agent that writes and edits content based on prompts",
        spec={"capabilities": ["write", "edit", "proofread"]},
        functions={"generate_content": "Creates content based on prompts"}
    )
]

# Insert agents
print("\nInserting agents...")
service.update_records(agents)

# Query to verify insertion
print("\nVerifying insertion...")
all_agents = service.select()
print(f"Found {len(all_agents)} agents")

# Modify an agent and insert again to test upsert
print("\nTesting upsert with modified agent...")
agents[0].description = "UPDATED: Agent that performs advanced web searches with summarization"
agents[0].spec["capabilities"].append("filter")

# Add a new agent
print("\nAdding a new agent during upsert...")
new_agent = Agent(
    id=uuid.uuid4(),
    name="AnalysisAgent",
    category="Analytics",
    description="Analyzes data and generates insights",
    spec={"capabilities": ["analyze", "visualize"]},
    functions={"analyze_data": "Performs data analysis on structured data"}
)
agents.append(new_agent)

# Perform upsert with both modified and new agents
service.update_records(agents)

# Verify upsert results
updated_agents = service.select()
print(f"Total agents after upsert: {len(updated_agents)}")

# Check if update was applied
research_agent = service.select(name="SearchAgent")[0]
print(f"Updated description: {research_agent['description']}")
print(f"Updated capabilities: {research_agent['spec']}")

# Step 3: Add embeddings for semantic search
print("\nAdding embeddings...")
embedding_results = service.add_embeddings(service.select())
print(f"Embeddings added: {embedding_results['embeddings_added']}")
print(f"Embedding success: {embedding_results['success']}")

# Step 4: Add entities to graph database
print("\nAdding entities to graph database...")
try:
    kuzu = KuzuDBService()
    
    agent_entities = [
        {"id": str(agent.id), "name": agent.name}
        for agent in agents
    ]
    count = kuzu.add_entities("p8.Agent", agent_entities)
    print(f"Added {count} entities to graph database")
    
    # Create a relationship between agents
    kuzu.create_relationship(
        str(agents[0].id),  # SearchAgent
        str(agents[2].id),  # AnalysisAgent
        "COLLABORATES_WITH",
        weight=0.9
    )
    print("Created relationship between SearchAgent and AnalysisAgent")
    
except Exception as e:
    print(f"Graph database operations failed: {e}")

# Step 5: Test entity lookup by name
print("\nTesting entity lookup by name...")
search_agent = service.get_entity_by_name("SearchAgent")
print(f"Found agent by name: {search_agent[0]['name'] if search_agent else 'Not found'}")

# Step 6: Test semantic search
print("\nTesting semantic search...")
search_results = service.semantic_search("summarize", limit=3)
print(f"Found {len(search_results)} results for 'summarize'")
for i, result in enumerate(search_results):
    print(f"{i+1}. {result['name']} - {result['description'][:50]}...")

# Cleanup (optional)
print("\nDropping entity...")
drop_result = service.drop_entity()
print(f"Drop success: {drop_result['success']}")
if not drop_result['success']:
    print(f"Drop errors: {drop_result['errors']}")

# Verify cleanup
print("\nFinal PyIceberg Status:")
final_status = service.get_iceberg_status()
print(f"Catalog loaded: {final_status.get('catalog_loaded', False)}")
print(f"Namespaces: {final_status.get('namespaces', [])}")
print(f"Tables: {final_status.get('tables', {})}")
```

This example covers all the steps in the flow:
1. Creating tables with PyIceberg catalog integration
2. Inserting and upserting records
3. Adding embeddings for semantic search
4. Adding entities to the graph database
5. Testing entity lookup and semantic search
6. Cleaning up resources

Each section includes diagnostic output to verify the operation succeeded and help troubleshoot any issues.



# Notes on Duck DB and Iceberg integration


⏺ The IcebergModelCatalog works with DuckDB for embeddings and indexes through a carefully designed
  integration approach. Here's how this integration functions:

  How IcebergModelCatalog Works with DuckDB Embeddings and Indexes

  1. Apache Iceberg as Metadata Layer
    - IcebergModelCatalog primarily serves as a metadata management layer
    - It provides schema definition, evolution capabilities, and table structure management
    - The actual storage of data can still be handled by DuckDB's native storage
  2. DuckDB's Iceberg Integration
    - DuckDB has native support for reading from and writing to Iceberg tables
    - The iceberg_scan() function in DuckDB allows querying Iceberg tables directly
    - This integration allows DuckDB to understand the schema defined by Iceberg
  3. Storage Coordination
    - Tables created by IcebergModelCatalog are registered in both the Iceberg catalog and in DuckDB
    - When data is written through IcebergModelCatalog, it maintains proper metadata
    - DuckDB can then read this data and apply its own optimizations (including indexing)
  4. Embeddings Implementation
    - Embedding tables (e.g., py_embeddings.namespace_table_embeddings) are created with a standard
  schema
    - These tables store vector data that can be queried efficiently by DuckDB
    - The vector columns are properly typed as arrays of floating-point values
  5. Vector Search Support
    - DuckDB's VSS (Vector Similarity Search) extension is loaded in the DuckDBService initialization
    - The vector columns created by IcebergModelCatalog are compatible with DuckDB's VSS functions
    - When we create tables with embedding fields, IcebergModelCatalog properly defines those fields
  6. Indexing Mechanism
    - After creating tables through IcebergModelCatalog, DuckDBService creates vector indexes
    - The _create_vector_indexes method executes DuckDB-specific indexing commands
    - These indexes work against the tables defined by Iceberg but stored in DuckDB's format
  7. Semantic Search Flow
    - When performing semantic search, we convert a query to embeddings
    - The search uses DuckDB's vector similarity functions (vss_cosine_distance or
  list_cosine_similarity)
    - The search joins the main table and the embedding table to return relevant records

  Key Integration Points

  1. Table Registration
  # Create catalog for this model
  catalog = IcebergModelCatalog(self.model)
  # Ensure the table exists
  table = catalog.create_table_for_model()
  2. Vector Index Creation
  # Create index for each embedding field
  index_name = f"idx_vector_{namespace}_{name}_{field}"
  index_query = f"""
  CREATE INDEX {index_name} ON {embedding_table} (
      embedding_vector vss_cosine_distance
  ) USING vss WHERE column_name = '{field}'
  """
  3. Semantic Search
  query_sql = f"""
  SELECT m.*, e.embedding_vector, 
         list_cosine_similarity(e.embedding_vector, ?) as similarity
  FROM {main_table} m
  JOIN {embedding_table} e ON m.id = e.source_record_id
  WHERE e.column_name = '{embedding_field}'
    AND list_cosine_similarity(e.embedding_vector, ?) >= {threshold}
  ORDER BY similarity DESC
  LIMIT {limit}
  """

  The key point is that Iceberg provides the metadata layer (schema definition, field types, and table
  structure), while DuckDB manages the actual storage, indexing, and query execution. When properly
  integrated, DuckDB can leverage its VSS extension to create and use indexes on vector data stored in
  tables defined by the Iceberg catalog.