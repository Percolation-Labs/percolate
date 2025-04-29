# Percolate Codebase Overview

## Project Summary
- Percolate is a relational-vector-graph/key-value database built on PostgreSQL for building agentic AI systems.
- It integrates vectors, graphs, and key-value stores within PostgreSQL, enabling multi-modal, agent-driven workflows in the data tier.

## Top-level Structure
- Dockerfile: Builds the Percolate container image (PostgreSQL with extensions, ollama, etc.).
- docker-compose.yaml: Launches services for local development (PostgreSQL, MinIO, etc.).
- percolate-cluster.yaml / ops/: Kubernetes manifests for deploying Percolate (Cloud Native PG).
- configmaps/: Placeholder for Kubernetes ConfigMaps used in ops.
- extension/: Zig-based PostgreSQL extension (p8) with SQL definitions and build scripts.
- integrations/: Microservices for dynamic tool / model invocation (static/dynamic MCP servers, OpenWebUI).
- clients/python/percolate/: Official Python client library and CLI for interacting with Percolate.
- docs/: Additional documentation (Troubleshooting, guides).
- studio/: Example projects and configuration for bootstrapping data in Percolate.
- README.md: High-level overview, setup instructions, examples.

## Extension
- Language: Zig (with pgsql extension).
- Directory:
  - src/: Zig source for p8 extension.
  - sql/: SQL scripts for schema and functions.
  - scripts/: Build and deployment helpers.

## Python Client (clients/python/percolate)
- Language & Tools: Python 3.10+, Poetry for dependency management.
- Structure:
  - percolate/: Python package.
    - api/: FastAPI-based HTTP API server (routes for auth, chat, entities, integrations, tasks, tools, admin).
    - cli.py: Command-line interface (p8) for project initialization, indexing, querying.
    - interface.py: Core abstractions for repository and agent interactions.
    - models/: Pydantic models (AbstractModel, MessageStack).
    - services/: LLM, database, and integration services.
    - utils/: Helper functions and common utilities.
  - notebooks/: Jupyter notebooks demonstrating usage and recipes.
  - test_percolate/, pytest.ini: Test suite and configuration.

## Integrations
- Dynamic MCP Server: Python service to serve functions loaded from Percolate (integrations/dynamic).
- OpenWebUI bindings and static MCP server (integrations/openwebui, p8mcp).

## Studio Projects
- studio/projects/default/percolate.yaml: Default project definition (apis, agents, models, etc.).
- Used by `p8 init` to bootstrap a local Percolate database project.

## Deployment & Operations
- Kubernetes manifests in ops/k8s and percolate-cluster.yaml.
- configmaps/ for storing environment/configuration secrets.

## Development & Setup
- Local:
  1. `docker compose up -d`
  2. `cd clients/python/percolate && poetry install`
  3. `poetry run p8 init` to bootstrap default project.
- Extension:
  - Install Zig, build with `zig build`, copy `.so` and SQL to Postgres extension directory.

## Documentation & Guides
- Main README.md covers quickstart, SQL usage, Python usage, CLI commands.
- docs/Troubleshooting.md for common issues.
- clients/python/percolate/notebooks for interactive tutorials.

## License
- MIT License (Copyright Percolation Labs).