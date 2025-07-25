# Percolate Documentation Consistency Report

This report summarizes all the inconsistencies found between the Percolate documentation and the actual implementation.

## Executive Summary

The Percolate documentation appears to be a mix of aspirational design, outdated information, and some accurate content. Major discrepancies exist across all documentation files, with the implementation often being either more sophisticated in some areas (security, agent architecture) or missing documented features entirely (Redis caching, many API endpoints).

## 1. README.md Issues

### Package Installation
- ✅ Correct: `pip install percolate-db` (package name is correct)
- ❌ Incorrect: `p8 query` command doesn't exist (actual command is `p8 ask`)

### SQL Examples
- ❌ `percolate()` function signature is wrong
  - Documented: `percolate(prompt TEXT, model TEXT DEFAULT 'gpt-4', temperature FLOAT DEFAULT 0.7)`
  - Actual: Much more complex with tool_names, system_prompt, token_override parameters
  - Returns different columns than documented

### Python API
- ❌ Import statement wrong: `from percolate import BaseModel, Agent`
  - Should be: `from percolate.models import BaseModel` (or AbstractModel)
  - Agent is a function, not a class to import

## 2. API Reference (02-api-reference.md)

### Major Issues:
- ❌ Authentication endpoints wrong (no email/password login, only Google OAuth)
- ❌ Entity endpoints are for AI agents, not general entities
- ❌ Audio endpoints use different workflow than documented
- ❌ Missing documentation for:
  - Integration endpoints (`/x/*`)
  - OpenAI-compatible endpoints (`/v1/*`)
  - TUS protocol implementation
  - Admin operations

### Non-existent Endpoints:
- `/auth/login` (email/password)
- `/auth/logout`
- `/entities` (general CRUD)
- `/audio/transcribe` (direct)
- `/codebase/index`

## 3. Database Usage (03-database-usage.md)

### Function Discrepancies:
- ❌ `p8.list_functions()` - doesn't exist
- ❌ `p8.search_functions()` - doesn't exist
- ❌ `p8.add_function()` - doesn't exist
- ❌ `p8.search_resources()` - doesn't exist (actual: `file_upload_search()`)
- ❌ `p8.generate_embedding()` - doesn't exist (actual: `get_embedding_for_text()`)

### Missing Documentation:
- Security functions (`set_user_context()`)
- Entity management functions
- Session management
- Agent architecture

## 4. Deployment (04-deployment.md)

### Major Discrepancies:
- ❌ Redis not implemented (documented extensively)
- ❌ Port 5008 used instead of 8000
- ❌ No Helm charts exist
- ❌ No monitoring stack implemented
- ❌ No HPA or advanced Kubernetes features
- ❌ Environment variables use `P8_` prefix, not documented names

## 5. Building Agents (05-building-agents.md)

### Conceptual Issues:
- ❌ Agent shown as class with methods, but it's actually a Pydantic model
- ❌ `Agent()` returns a ModelRunner, not an agent instance
- ❌ No `create_conversation()` method
- ❌ Missing documentation for:
  - Row-level security in agents
  - Agent persistence
  - Streaming support
  - CallingContext

## 6. Data Models (06-data-models.md)

### Major Issues:
- ❌ `PercolateBaseModel` doesn't exist (uses `AbstractModel`)
- ❌ Many documented models don't exist
- ❌ Many implemented models aren't documented
- ❌ Field names and types often wrong

### Missing Models in Docs:
- LanguageModelApi
- TokenUsage
- ResearchIteration
- Engram (user memory)
- 20+ other models

## 7. Model Runners (07-model-runners-proxy.md)

### Architecture Wrong:
- ❌ No abstract ModelRunner with providers
- ❌ No LLMProvider hierarchy
- ❌ Database-driven configuration not documented
- ❌ Missing caching mechanisms
- ❌ Function calling works differently

## 8. Authentication (08-authentication.md)

### Already Updated:
- ✅ This was updated during our session
- ✅ Now reflects actual implementation
- ✅ Correct endpoints and flows

## Key Recommendations

1. **Immediate Actions:**
   - Update all function signatures and return types
   - Remove references to non-existent features
   - Fix all import statements and code examples
   - Update CLI command documentation

2. **Documentation Rewrite Needed:**
   - API Reference needs complete rewrite
   - Database usage should reflect actual functions
   - Model documentation should match implementation
   - Deployment should show actual configurations

3. **Feature Decisions:**
   - Implement Redis if needed or remove from docs
   - Implement missing endpoints or remove from docs
   - Add monitoring/observability or remove from docs
   - Standardize on actual port numbers (5008)

4. **Add Missing Documentation:**
   - MCP server implementation
   - Integration endpoints
   - Security model (RLS, user context)
   - Actual agent architecture
   - Session management
   - User memory system

## Conclusion

The documentation appears to represent an earlier or idealized version of Percolate. The actual implementation has evolved significantly, with some features more advanced (security, agent system) and others not implemented (Redis, monitoring). A comprehensive documentation update is needed to help developers understand and use the actual system effectively.