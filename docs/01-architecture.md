# Percolate Architecture Guide

## Table of Contents
1. [Overview](#overview)
2. [Core Design Philosophy](#core-design-philosophy)
3. [System Architecture](#system-architecture)
4. [Component Architecture](#component-architecture)
5. [Data Flow](#data-flow)
6. [Security Architecture](#security-architecture)
7. [Scalability & Performance](#scalability--performance)

## Overview

Percolate is an approach to building AI-powered applications that pushes intelligence into the database tier. By combining relational, vector, graph, and key-value capabilities in a single PostgreSQL-based system, Percolate enables developers to build sophisticated agentic systems with minimal application code.

```mermaid
graph TB
    subgraph "Application Layer"
        A[Python Client]
        B[REST API]
        C[Web UI]
    end
    
    subgraph "API Layer"
        D[FastAPI Server]
        E[Authentication]
        F[Model Proxy]
    end
    
    subgraph "Intelligence Layer"
        G[Agent Runtime]
        H[Function Registry]
        I[Model Runners]
    end
    
    subgraph "Data Layer"
        J[PostgreSQL]
        K[pgvector]
        L[Apache AGE]
        M[pg_http]
    end
    
    subgraph "External Services"
        N[LLM Providers]
        O[External APIs]
        P[Object Storage]
    end
    
    A --> D
    B --> D
    C --> D
    D --> G
    D --> E
    F --> N
    G --> H
    G --> I
    I --> F
    G --> J
    J --> K
    J --> L
    J --> M
    H --> O
    D --> P
```

## Core Design Philosophy

### 1. **Intelligence in the Database**
Traditional AI applications separate data storage from intelligence, leading to complex architectures. Percolate embeds AI capabilities directly in PostgreSQL.

### 2. **Multi-Modal Data Platform**
Percolate treats all data types as first-class citizens:
- **Relational**: Traditional structured data
- **Vector**: Embeddings for semantic search
- **Graph**: Relationships and networks
- **Key-Value**: Flexible document storage

### 3. **Declarative Agent Development**
Agents are defined as Pydantic models with:
- Automatic function discovery
- Built-in semantic search
- Type-safe interfaces
- Self-documenting capabilities

## System Architecture

### Core Components

```mermaid
graph LR
    subgraph "PostgreSQL Extensions"
        A[Core PostgreSQL]
        B[pgvector<br/>Embeddings]
        C[Apache AGE<br/>Graph]
        D[pg_http<br/>HTTP Client]
        E[pg_trgm<br/>Text Search]
    end
    
    subgraph "Percolate Schema"
        F[p8 Functions]
        G[Security Layer]
        H[Agent Runtime]
    end
    
    A --> F
    B --> F
    C --> F
    D --> F
    E --> F
    F --> G
    G --> H
```

## Component Architecture

### 1. **Database Layer**

The database layer is built on PostgreSQL 16+ with critical extensions:

```sql
-- Core extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;
CREATE EXTENSION IF NOT EXISTS http;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Percolate schema
CREATE SCHEMA IF NOT EXISTS p8;
```

Key database components:
- **p8 schema**: Contains all Percolate functions and tables
- **Row-level security**: Automatic user context propagation
- **Audit logging**: Complete conversation history
- **Vector indexes**: High-performance semantic search

### 2. **API Layer**

FastAPI-based REST API with:
- **OpenAPI compliance**: Full API documentation
- **Authentication**: OAuth2, bearer tokens, sessions
- **Streaming**: Server-sent events for real-time responses
- **Multi-dialect**: Support for OpenAI, Anthropic, Google formats

### 3. **Agent Runtime**

The agent runtime orchestrates:
- **Function discovery**: Semantic search over available functions
- **Planning**: Multi-step reasoning chains
- **Execution**: Tool invocation and result processing
- **Context management**: User-specific data access

```mermaid
sequenceDiagram
    participant User
    participant API
    participant Agent
    participant Functions
    participant LLM
    
    User->>API: Query
    API->>Agent: Create session
    Agent->>Functions: Discover tools
    Agent->>LLM: Plan execution
    LLM->>Agent: Execution plan
    loop Execute steps
        Agent->>Functions: Call function
        Functions->>Agent: Return result
        Agent->>LLM: Process result
    end
    Agent->>API: Final response
    API->>User: Stream response
```

## Data Flow

### 1. **Query Processing**

```mermaid
graph LR
    A[User Query] --> B[API Server]
    B --> C{Auth Check}
    C -->|Valid| D[Agent Selection]
    C -->|Invalid| E[401 Error]
    D --> F[Context Loading]
    F --> G[Function Discovery]
    G --> H[LLM Processing]
    H --> I[Function Execution]
    I --> J[Response Generation]
    J --> K[Stream to User]
```

### 2. **Content Indexing**

```mermaid
graph TB
    A[Content Source] --> B[File Upload]
    B --> C[Content Extraction]
    C --> D[Chunking]
    D --> E[Embedding Generation]
    E --> F[Vector Storage]
    F --> G[Metadata Storage]
    G --> H[Index Update]
```

## Security Architecture

### 1. **Authentication & Authorization**

```mermaid
graph TB
    A[User Request] --> B{Auth Type}
    B -->|OAuth| C[Google OAuth]
    B -->|Bearer| D[Token Validation]
    B -->|Session| E[Session Check]
    
    C --> F[User Context]
    D --> F
    E --> F
    
    F --> G[Row-Level Security]
    G --> H[Query Execution]
```

### 2. **Data Isolation**

- **User context**: Automatically propagated through all queries
- **Row-level security**: PostgreSQL RLS policies
- **Function access**: Per-user function permissions
- **Audit trail**: Complete activity logging

## Scalability & Performance

### 1. **Horizontal Scaling**

```mermaid
graph TB
    subgraph "API Tier"
        A[API Instance 1]
        B[API Instance 2]
        C[API Instance N]
    end
    
    subgraph "Database Tier"
        D[Primary]
        E[Replica 1]
        F[Replica N]
    end
    
    subgraph "Caching"
        G[Redis Cluster]
        H[CDN]
    end
    
    A --> D
    B --> E
    C --> F
    
    A --> G
    B --> G
    C --> G
```

### 2. **Performance Optimizations**

- **Vector indexes**: HNSW for fast similarity search
- **Connection pooling**: pgBouncer for efficient connections
- **Query optimization**: Prepared statements and caching
- **Streaming responses**: Reduced memory footprint

### 3. **Resource Management**

```yaml
# Kubernetes resource limits
resources:
  api:
    requests:
      memory: "512Mi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "2000m"
  
  postgres:
    requests:
      memory: "4Gi"
      cpu: "2000m"
    limits:
      memory: "16Gi"
      cpu: "8000m"
```

## Best Practices

### 1. **Development**
- Use declarative agent definitions
- Leverage built-in function discovery
- Implement proper error handling
- Follow type safety guidelines

### 2. **Deployment**
- Use connection pooling
- Configure appropriate resource limits
- Enable monitoring and logging
- Implement backup strategies

### 3. **Security**
- Always use authentication
- Implement least-privilege access
- Regular security audits
- Encrypt sensitive data

## Conclusion

Percolate's architecture represents a paradigm shift in building AI applications. By moving intelligence into the database tier and providing a unified multi-modal data platform, it enables developers to build sophisticated agentic systems with unprecedented simplicity and performance.