# Database Usage Guide

## Table of Contents
1. [Overview](#overview)
2. [Direct SQL vs Python Client](#direct-sql-vs-python-client)
3. [Core SQL Functions](#core-sql-functions)
4. [Entity Management](#entity-management)
5. [Security & Context](#security--context)
6. [Graph Operations](#graph-operations)
7. [Vector Search & Embeddings](#vector-search--embeddings)
8. [Advanced Patterns](#advanced-patterns)
9. [Best Practices](#best-practices)

## Overview

Percolate extends PostgreSQL with AI capabilities, allowing you to run queries directly in SQL. This guide covers both direct SQL usage and Python client approaches.

## Direct SQL vs Python Client


**Example:**
```sql
-- Direct AI query in SQL
SELECT * FROM percolate('Summarize our Q4 sales performance');

-- Query with specific agent
SELECT * FROM percolate_with_agent('Analyze this data', 'p8.PercolateAgent');
```

### Python Client

 
**Example:**
```python
import percolate as p8

# Use repository pattern
from percolate.models import User
repo = p8.repository(User)
users = repo.select(email="user@example.com")

# Run AI queries
response = p8.query("SELECT * FROM percolate('What can you help with?')")
```

## Core SQL Functions

### percolate()

The main AI query function. Note: This is a wrapper around percolate_with_agent().

```sql
-- Simple query
SELECT * FROM percolate('What is the status of our project?');

-- Returns: (message_response, tool_calls, tool_call_result, session_id_out, status)
```

### percolate_with_agent()

Query with a specific agent.

```sql
SELECT * FROM percolate_with_agent(
    'Find information about machine learning',
    'p8.PercolateAgent'  -- agent name
);
```

### run()

Execute an agentic loop with more control.

```sql
SELECT * FROM run(
    question := 'Analyze our sales data',
    max_iterations := 5,
    model := 'gpt-4',
    agent := 'sales-analyst'
);
```

## Entity Management

### Register Entities

```sql
-- Register an entity type with supporting views
SELECT p8.register_entities(SomeModel);
```

### Get Entities

```sql
-- Get specific entities by name
SELECT * FROM p8.get_entities(ARRAY['customer_123', 'product_456']);

-- Fuzzy entity matching
SELECT * FROM p8.get_fuzzy_entities(
    ARRAY['john doe', 'jane smith'],
    0.8  -- similarity threshold
);

-- Get connected entities
SELECT * FROM p8.get_connected_entities('customer');
```

### Query Entities

```sql
-- Entity-specific search
SELECT * FROM p8.query_entity(
    'Find recent purchases',
    'public.Orders'
);
```

## Security & Context

### Set User Context

Required for row-level security:

```sql
-- Set user context for current session
SELECT p8.set_user_context('123e4567-e89b-12d3-a456-426614174000'::uuid);

-- All subsequent queries will respect user's permissions
```


### Row-Level Security

```sql
-- Attach RLS policy to a table
SELECT p8.attach_rls_policy(
    p_table_name := 'sensitive_data',
    p_role_levels := ARRAY[1, 5, 10],
    p_id_column := 'user_id'
);
```

## Graph Operations

### Add Relationships

```sql
-- Add multiple relationships at once
SELECT p8.add_relationships_to_node('[
    {
        "from_node": "user_123",
        "to_node": "product_456",
        "relationship": "PURCHASED"
    },
    {
        "from_node": "user_123",
        "to_node": "category_789",
        "relationship": "INTERESTED_IN"
    }
]'::jsonb);
```

### Query Relationships

```sql
-- Get relationships for entities
SELECT * FROM p8.get_relationships(
    p_names := ARRAY['user_123'],
    p_relationship_types := ARRAY['PURCHASED', 'VIEWED'],
    p_directions := ARRAY['outgoing'],
    p_max_depth := 2
);

-- Find paths between nodes
SELECT * FROM p8.get_paths(
    ARRAY['user_123', 'product_789'],
    max_length := 5,
    max_paths := 10
);
```

### Cypher Queries

```sql
-- Execute Cypher queries (Apache AGE)
SELECT * FROM cypher_query(
    'MATCH (u:User)-[:PURCHASED]->(p:Product) 
     WHERE u.id = ''user_123'' 
     RETURN u, p',
    'user agtype, product agtype'
);
```

## Vector Search & Embeddings

### Generate Embeddings

```sql
-- Fetch embeddings for text
SELECT p8.fetch_embeddings(
    '["machine learning", "artificial intelligence"]'::jsonb,
    'gpt-4',
    'text-embedding-ada-002'
);

-- Insert entity embeddings
SELECT p8.insert_entity_embeddings('Customer');
```

### Vector Search in Python

```python
# Search with embeddings
results = p8.repository(Resources).select(
    embedding__similarity="machine learning concepts"
)
```

## More

### Function Evaluation

```sql
-- Execute function calls (tools)
SELECT p8.eval_function_call('{
    "name": "search",
    "arguments": {
        "query": "recent orders"
    }
}'::text);
```

### Session Management

```sql
-- Resume a previous session
SELECT p8.resume_session(
    p_session_id := '550e8400-e29b-41d4-a716-446655440000'::uuid,
    p_messages := '[{"role": "user", "content": "Continue our discussion"}]'::jsonb,
    p_user_id := '123e4567-e89b-12d3-a456-426614174000'::uuid
);
```

### Tool Discovery

```sql
-- Get tools by name
SELECT * FROM p8.get_tools_by_name(
    ARRAY['search', 'calculate'],
    'openai'  -- scheme
);

-- Get agent-specific tools
SELECT * FROM p8.get_agent_tools(
    p_agent_name := 'research-assistant',
    p_user_id := '123e4567-e89b-12d3-a456-426614174000'::uuid
);
```


## Python Repository Pattern

The Python client uses a repository pattern for data access:

```python
import percolate as p8
from percolate.models import YourModel

# Get repository for a model
repo = p8.repository(YourModel)

# Check if entity exists
if not repo.entity_exists:
    repo.register()

# CRUD operations
records = repo.select(field="value")
repo.update_records([record1, record2])

# Direct SQL
results = repo.execute("SELECT * FROM your_table WHERE condition = %s", ["value"])
```

This approach provides type safety while maintaining the flexibility of SQL when needed.