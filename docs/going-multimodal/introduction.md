---
description: >-
  Percolate is a multimodal database that manages relational, key-value, graph
  and vector data for building AI applications. We can combine indexes when
  querying Percolate.
---

# Introduction

Even without getting deeper into agent orchestration with Percolate, you should find the dockerized Postgres instance with extensions for vector, graph and HTTP queries useful. Below we briefly introduce the 5 query modalities in Percolate.

<figure><img src="../.gitbook/assets/image (3).png" alt=""><figcaption></figcaption></figure>

### 1 Relational

Percolate is built on Postgres so it goes without saying that you can use SQL and relational data modeling. While Percolate supports query modalities like graph and vector, Percolate is entity-first which means that semantic entity structures take center stage. Tables, entities and agents are in fact synonymous in Percolate. When you create an agent with a structured output schema, a table is also created, which allows exporting data from the agent e.g. a Task agent.&#x20;

The field metadata and system prompt can be considered extended table schema in the Postgres database. They allow for natural language to SQL query mapping as we can provided field metadata and also enum values for query construction. We will provide examples of generating SQL from natural language in later sections.

### 2 Vector

We add the pg\_vector extension and this is activated when you spin up the container for the first time. You can follow the [documentation for pg\_vector ](https://github.com/pgvector/pgvector)to learn more about adding vector embeddings and querying. In Percolate when we added entities, an indexing process adds embeddings for any fields that are configured for embeddings. The semantic entity information is provided in the Pydantic object or JsonSchema that was used to register the entity. You can add multiple embeddings to fields

### 3 Graph

We add the age\_graph extension and this is activated when you spin up the container for the first time. We create the default Percolate graph in the percolate schema but you can add your own graphs. The extension allows you to create graphs and query the graphs with Cypher. This can be used to build relationships between entities and to construct knowledge graphs. In Percolate we treat a graph as an index. Entity nodes and relationships are indexed by background processes. You can read more about using Cypher in the [AGE documentation](https://age.apache.org/age-manual/master/intro/overview.html).&#x20;

### 4 Key-Value

When we add named entities to Percolate tables, we also index entities as graph nodes, making the graph database our key-value store. This can be useful if language models need to lookup entities without knowing what those entities are. There is a `get_entities` database function which can be used as a tool for any agent.&#x20;

### 5 HTTP

HTTP/REST is the fifth query modality. It goes without saying that care must be taken when calling HTTP endpoints from the database. In Percolate the HTTP extension is used to call language models and tools. For testing it is fine to do this synchronously but at scale we turn to async processes and background workers. You can read more about the HTTP extension in Postgres [here](https://github.com/pramsey/pgsql-http).







