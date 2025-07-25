# Percolate Testing Guide

This document provides comprehensive testing procedures for validating Percolate database functionality, including entity indexing, API connectivity, and full system integration. WE create the primary schema and then register data and models from the cli based on the latest version of the code. We do not currently have proper migrations for Percolate.

## Complete Fresh Installation Process

This section provides step-by-step instructions for a complete tear-down and fresh setup of the Percolate system. This is the **primary testing workflow** that validates the entire installation process from scratch.

### Prerequisites

Ensure you have the following environment variables set for language model providers:
```bash
export OPENAI_API_KEY="your_key_here"
export ANTHROPIC_API_KEY="your_key_here"
export GROQ_API_KEY="your_key_here"
# Set any other API keys you plan to use
```

**Note**: If you've recently changed Pydantic models, see [Model-to-SQL Synchronization](#model-to-sql-synchronization) at the end of this document.

### Step 1: Complete Tear-Down

Stop all services and remove all persistent data:

```bash
# Navigate to project root
cd /path/to/percolate

# Stop all running containers
docker compose down

# Remove all volumes and persistent data (DESTRUCTIVE - removes all data!)
docker compose down -v
docker volume prune -f

# Optional: Remove images if you want to rebuild from scratch
docker rmi percolate-api-local:latest percolationlabs/percolate-api 2>/dev/null || true
```

**⚠️ Warning**: This completely destroys all database data, settings, and embeddings.

### Step 2: Fresh Container Startup

Start the containers from scratch. The database will automatically run all installation scripts:

```bash
# Start all services - database will auto-initialize from ./extension/sql/ scripts
docker compose up -d

# Watch logs to ensure clean startup (optional)
docker compose logs -f percolate
```

**Expected Initialization Process:**
1. PostgreSQL starts with empty database
2. Docker auto-runs scripts from `./extension/sql/:/docker-entrypoint-initdb.d/`:
   - `00_install.sql` - Extensions, schemas, basic functions
   - `01_add_functions.sql` - All Percolate functions  
   - `02_create_primary.sql` - Primary model tables
   - `03_create_secondary.sql` - Secondary model tables
   - `10_finalize.sql` - Settings, API tokens, session creation
3. AGE extension configured with `session_preload_libraries = 'age'`
4. Database generates internal API token for service authentication
5. Percolate-api service starts and connects to database

**Verify Installation Success:**
```bash
# Check all services are running
docker compose ps

# Verify database initialization completed
docker compose logs percolate | grep "database system is ready to accept connections"

# Verify API service is healthy  
docker compose logs percolate-api | grep "Application startup complete"
```

### Step 3: Populate with CLI Init

The `p8 init` command syncs environment API keys and populates test data:

```bash
# Navigate to Python client
cd clients/python/percolate

# Run initialization - syncs API keys and creates test data
poetry run p8 init
```

**Expected Output:**
```
🔑 Syncing env keys if they are set for language model providers:
{'OPENAI_API_KEY': True, 'ANTHROPIC_API_KEY': True, 'GROQ_API_KEY': True, ...}

🔍 Indexing 437 items...
✅ Registered 15 language model APIs
✅ Created 23 agents with descriptions  
✅ Added 108 functions and tools
✅ Populated test entities and relationships

📚 Adding API schemas:
Adding API uri='https://petstore.swagger.io/v2/swagger.json'
✅ Sample API schema imported

🎉 Initialization complete! System ready for testing.
```

**What Init Creates:**
- Language model API configurations synced from environment variables
- Test agents (p8.Agent entities) with embeddings for search testing
- Function definitions for tool calling
- Sample data for entity relationship testing
- API schema examples for testing function calls

### Step 4: Run Comprehensive Diagnostic

Validate the complete system is working:

```bash
# Run full diagnostic suite from project root
cd /path/to/percolate
python scripts/diagnostic_test_suite.py --save-report
```

**Expected Results for Fresh Installation:**
```
🔬 Percolate Comprehensive Diagnostic Suite
======================================================================
📊 Testing Core Infrastructure...
✅ PASS [database] connectivity: Connected as postgres to app
✅ PASS [database] extensions: All 4 extensions installed  
✅ PASS [schema] model_tables: All 13 model tables exist

🔧 Testing all function categories...
✅ PASS [core] All 4/4 functions available (100.0%)
✅ PASS [entities] All 6/6 functions available (100.0%) 
✅ PASS [cypher] All 5/5 functions available (100.0%)
✅ PASS [search] All 4/4 functions available (100.0%)
✅ PASS [indexing] All 4/4 functions available (100.0%)
✅ PASS [requests] All 6/6 functions available (100.0%)
✅ PASS [tools] All 4/4 functions available (100.0%)
✅ PASS [utils] All 2/2 functions available (100.0%)

🕸️ Testing graph functionality...
✅ PASS [graph] AGE extension working correctly (500+ nodes)
✅ PASS [graph] get_entities works with p8.Agent search
✅ PASS [graph] get_fuzzy_entities works with agent search

🤖 Testing AI functionality...
✅ PASS [ai] percolate_query: AI query executed successfully
✅ PASS [ai] percolate_math: AI correctly answered math question

======================================================================
📊 Success Rate: 100.0% (56/56 tests passing)
💡 Recommendations: 🎉 All diagnostics passed! System is fully operational.
```

**Success Criteria:**
- **100.0% success rate** (all 56 tests passing)
- Database connectivity and all extensions working
- All 13 model tables created and accessible
- All 35+ functions available across 8 categories
- AGE graph extension working with 500+ test nodes
- AI queries processing correctly with math validation
- API services responding to health checks

### Step 5: Validate Key Functionality

Test the core features that should work after fresh installation:

```bash
# Test database connection and basic query
PGPASSWORD=postgres psql -h localhost -p 5438 -U postgres -d app -c "SELECT message_response FROM percolate('What is 2 + 2?') LIMIT 1;"

# Expected: Returns AI response with "4" or "four"
```

```sql
-- Test entity search with populated agents
SELECT * FROM p8.get_entities(ARRAY['agent']) LIMIT 5;

-- Test graph functionality  
SET search_path = ag_catalog, '$user', public;
SELECT * FROM cypher('percolate', $$ MATCH (n) RETURN count(n) $$) as (count agtype);

-- Test API service connectivity
SELECT p8.ping_service('percolate-api');
```

### Troubleshooting Fresh Installation

**If diagnostic tests fail:**

1. **Check Docker services:**
   ```bash
   docker compose ps
   docker compose logs percolate
   docker compose logs percolate-api
   ```

2. **Verify initialization completed:**
   ```bash
   # Check if all SQL scripts ran successfully
   docker compose logs percolate | grep -E "(00_install|01_add_functions|02_create_primary|03_create_secondary|10_finalize)"
   
   # Verify API token was generated
   PGPASSWORD=postgres psql -h localhost -p 5438 -U postgres -d app -c "SELECT value FROM p8.\"Settings\" WHERE key = 'P8_API_KEY';"
   ```

3. **Re-run init if needed:**
   ```bash
   cd clients/python/percolate
   poetry run p8 init
   ```

4. **For ARM64/Apple Silicon:**
   ```bash
   # Build local API image if getting "Illegal instruction" errors
   cd clients/python/percolate
   docker buildx build --platform linux/arm64 -t percolate-api-local:latest --load .
   
   # Update docker-compose.yaml to use: image: percolate-api-local:latest
   docker compose up -d percolate-api
   ```

---

## Quick System Health Check

### 1. Database Connectivity Test
```sql
-- Test basic database connection and extensions
SELECT version(), current_database(), current_user;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('age', 'http', 'vector', 'pg_trgm');
```

### 2. API Service Connectivity Test

#### Core AI Functionality Test (Primary)
```sql
-- Test if AI processing is working (tests OpenAI/external API connectivity)
SELECT message_response FROM percolate('ping test - are you working?') LIMIT 1;
```

**Expected Results:**
- **AI Working**: Returns response like `"Yes, I am working and ready to assist you!"`
- **AI Failing**: Error about missing API keys or model unavailable

#### Internal API Service Test (Secondary)
```sql
-- Test if internal percolate-api service is accessible for indexing
SELECT p8.ping_service('percolate-api');
```

**Expected Results:**
- When internal API is **UP**: `"status": "up"` with HTTP status and response time
- When internal API is **DOWN**: `"status": "down"` with error details

**Note**: The percolate function can work for AI queries even if the internal API service is down. The internal API is primarily used for indexing and admin functions.

### 3. Core Function Availability Test
```sql
-- Test core percolate function
SELECT message_response FROM percolate('What is 2 + 2?') LIMIT 1;
```

## Authentication and Token Management

### Database-Generated API Token

The Percolate system uses a database-generated API token for internal service authentication:

1. **Token Generation**: During installation (`10_finalize.sql`), a unique UUID token is generated and stored in:
   - `p8."Settings"` table with key `P8_API_KEY`
   - `p8."ApiProxy"` table for the 'percolate' service

2. **Token Usage**: The database triggers use this token to authenticate with the API:
   ```sql
   -- The notify_entity_updates() trigger function retrieves the token:
   SELECT token FROM p8."ApiProxy" WHERE name = 'percolate'
   -- And uses it in the Authorization header:
   Authorization: Bearer <token>
   ```

3. **API Validation**: The API validates incoming tokens by:
   - Loading the current token from database: `load_db_key('P8_API_KEY')`
   - Comparing against the bearer token in the request
   - Also accepting the postgres password as a fallback

4. **Health Check**: The docker-compose includes a health check to ensure the database has generated the token before starting the API service.

### Troubleshooting Token Issues

If you see "401 Unauthorized" errors:
1. Check the token in the database:
   ```sql
   SELECT value FROM p8."Settings" WHERE key = 'P8_API_KEY';
   SELECT token FROM p8."ApiProxy" WHERE name = 'percolate';
   ```
2. Ensure both values match
3. Verify the API can connect to the database to load the token
4. Check timing - the API must start after the database initialization completes

## Complete Entity Indexing Test Flow

This is the **complete test flow** demonstrated during system validation on 2025-07-25:

### Automatic vs Manual Indexing

Percolate supports two indexing modes:

1. **Automatic Indexing** (requires percolate-api service):
   - Triggers fire on INSERT/UPDATE
   - Calls `http://percolate-api:5008/admin/index/`
   - Embeddings created asynchronously
   - **Current Status**: ✅ Working correctly with proper token authentication

2. **Manual Indexing** (works without API):
   - Call `p8.insert_entity_embeddings()` function
   - Direct embedding generation
   - Useful for testing and troubleshooting

### Step 1: Create Test Entity
```sql
-- Insert a test user to trigger indexing workflows
INSERT INTO p8."User" (id, email, name, description) 
VALUES (
    gen_random_uuid(), 
    'test@example.com', 
    'Test User', 
    'A test user for checking indexing triggers'
) 
RETURNING id, email, name;
```

### Step 2: Verify Manual Embedding Generation
```sql
-- Manually trigger embedding creation for the User table
SELECT p8.insert_entity_embeddings('p8.User', 'YOUR_OPENAI_API_KEY');
```

### Step 3: Verify Embeddings Were Created
```sql
-- Check if embeddings were generated for our test user
SELECT 
    source_record_id, 
    column_name, 
    embedding_name, 
    (embedding_vector IS NOT NULL) as has_embedding,
    created_at
FROM p8_embeddings."p8_User_embeddings" 
WHERE source_record_id = 'YOUR_USER_ID_FROM_STEP_1';
```

**Actual Test Result (2025-07-25):**
```
source_record_id                     | column_name | embedding_name         | has_embedding | created_at
-------------------------------------|-------------|------------------------|---------------|------------
98f3bb87-be4b-4c06-a518-06ca18701c45 | description | text-embedding-ada-002 | t             | 2025-07-25...
```

### Step 4: Test Vector Search
```sql
-- Test vector similarity search
SELECT * FROM p8.vector_search_entity('test user', 'p8.User', 0.8, 5);
```

**Actual Test Result (2025-07-25):**
```
id                                   | vdistance
-------------------------------------|-------------------
98f3bb87-be4b-4c06-a518-06ca18701c45 | 0.573138563937856
```

### Step 5: Test Graph Indexing
```sql
-- Add entities to the graph database
SELECT p8.add_nodes('p8.User');

-- Verify graph has nodes (AGE is preloaded at session level)
SET search_path = ag_catalog, '$user', public; 
SELECT * FROM cypher('percolate', $$ MATCH (n) RETURN count(n) $$) as (count agtype);
```

### Step 6: Test AI-Powered Entity Search
```sql
-- Test percolate function with entity search
SELECT message_response 
FROM percolate('Find users named Test') 
LIMIT 1;
```

**Expected Behavior:**
- Function correctly identifies `get_entities` tool
- Calls tool with appropriate parameters: `{"keys": ["Test"]}`
- Returns relevant results or empty response

## Comprehensive Diagnostic Test

Run the full diagnostic suite:

```bash
cd /path/to/percolate
python scripts/diagnostic_test_suite.py --save-report
```

**Success Criteria:**
- **100.0% success rate** (all 56 tests passing)
- **100%** for all function categories: core, entities, cypher, search, indexing, requests, tools, utils
- All language model APIs configured and accessible
- AGE graph extension working with 500+ test nodes
- AI queries processing correctly

## Environment Setup Validation

### API Keys Configuration
```bash
# Run the init process to sync environment variables
cd clients/python/percolate
poetry run p8 init
```

**Expected Output:**
```
syncing env keys if they are set for language model providers:
{'XAI_API_KEY': True, 'GROQ_API_KEY': True, 'OPENAI_API_KEY': True, ...}
Indexing 437 items
Adding API uri='https://petstore.swagger.io/v2/swagger.json'
```

### Docker Services Status
```bash
# Check all services are running
docker compose ps

# Expected services: percolate-api, percolate (postgres), ollama-service, minio
# All should show "Up" status
```

## Service Diagnostic Functions

### p8.ping_service() - Test Service Connectivity

This function provides a reliable way to test if services are accessible from the database:

```sql
-- Test specific services
SELECT p8.ping_service('percolate-api');     -- Internal API service
SELECT p8.ping_service('ollama');            -- Ollama AI service  
SELECT p8.ping_service('minio');             -- MinIO object storage

-- Test custom URL
SELECT p8.ping_service('http://localhost:5008/health');

-- Test all services at once  
SELECT p8.ping_all_services();
```

**Use Cases:**
- **Docker troubleshooting**: Verify containers are accessible
- **Network debugging**: Test service-to-service connectivity  
- **Health monitoring**: Automated service status checks
- **Integration testing**: Validate end-to-end connectivity

**Sample Output (Service Down):**
```json
{
  "url": "http://percolate-api:5008/health",
  "error": "Connection refused", 
  "status": "down",
  "service": "percolate-api",
  "response_time_ms": 63.31,
  "timestamp": "2025-07-25T11:01:39.488694"
}
```

**Sample Output (Service Up):**
```json
{
  "url": "http://percolate-api:5008/health",
  "status": "up", 
  "http_status": 200,
  "service": "percolate-api",
  "response_time_ms": 45.22,
  "response_body": "OK",
  "timestamp": "2025-07-25T11:01:39.488694"
}
```

## Troubleshooting Common Issues

### API Connection Failures
**Symptom:** `Failed to connect to percolate-api port 5008`

**Solution:**
1. Check API container status: `docker compose ps`
2. Test API ping: `SELECT p8.ping_service('percolate-api')`
3. Restart with environment variables: `docker compose up -d`

### Docker Architecture Issues (Apple Silicon/ARM64)
**Symptom:** Container exits immediately with "Illegal instruction" errors when running on Apple Silicon Macs

**Root Cause:** The pre-built `percolationlabs/percolate-api` image is AMD64-only, which causes CPU instruction incompatibility on ARM64 systems.

**Solution:** Build the image locally for ARM64:
```bash
# Navigate to the Python client directory
cd clients/python/percolate

# Build for ARM64 specifically (faster for local development)
docker buildx build --platform linux/arm64 -t percolate-api-local:latest --load .

# Update docker-compose.yaml to use local image
# Change: image: percolationlabs/percolate-api
# To:     image: percolate-api-local:latest
# Remove: platform: linux/amd64

# Restart the service
docker compose up -d percolate-api
```

**Multi-platform Build (for distribution):**
```bash
# Create buildx builder if needed
docker buildx create --use

# Build for multiple platforms and push to registry
docker buildx build --platform linux/amd64,linux/arm64 -t percolationlabs/percolate-api:latest --push .
```

**Important Notes:**
- First build will be slow (~2-5 minutes) as it installs all dependencies
- Subsequent builds use cached layers and are much faster
- The `--load` flag only works with single platform builds
- For multi-platform builds, use `--push` to send to registry

### Missing Functions
**Symptom:** `function p8.xxx does not exist`

**Solution:**
1. Rebuild SQL: `python scripts/rebuild_sql_from_staging.py`
2. Apply SQL files: `PGPASSWORD=postgres psql -h localhost -p 5438 -U postgres -d app -f extension/sql/01_add_functions.sql`

### Type Mismatch Errors (UUID vs TEXT)
**Symptom:** `operator does not exist: uuid = text` during RLS policy creation

**Root Cause:** Pydantic model field type doesn't match SQL table definition (e.g., PlanModel.userid)

**Solution:**
1. Fix the Pydantic model field type (e.g., `userid: typing.Optional[uuid.UUID | str]`)
2. Regenerate SQL files:
   ```bash
   cd clients/python/percolate
   poetry run python -c "from percolate.models import bootstrap; bootstrap(apply=False, root='/path/to/percolate/extension/')"
   ```
3. Restart Docker with fresh volumes to apply new schema

### Embedding Generation Failures
**Symptom:** No embeddings created after entity insertion

**Solution:**
1. Verify API keys: Check environment variables are set
2. Manual trigger: `SELECT p8.insert_entity_embeddings('p8.User', 'api_key')`
3. Check model availability: `SELECT * FROM p8."LanguageModelApi"`

### Graph Database Issues
**Symptom:** `relation "ag_graph" does not exist`

**Solution:**
1. AGE is preloaded at session level: `SET search_path = ag_catalog, '$user', public;`
2. Verify graph exists: `SELECT * FROM ag_graph;`
3. Create if missing: Follow AGE setup in `00_install.sql`

## Performance Benchmarks

### Expected Response Times
- **Simple Query:** `percolate('2+2')` → ~1-3 seconds
- **Entity Search:** Vector search → ~50-200ms  
- **Embedding Generation:** ~200-500ms per text
- **Graph Operations:** Cypher queries → ~10-50ms

### Resource Usage
- **Database:** ~100-500MB RAM for basic operations
- **API Container:** ~200-800MB RAM depending on models
- **Disk:** ~50MB for extensions, ~varies for embeddings

## Success Indicators

✅ **System is fully operational when:**
- Diagnostic suite shows **100.0% success rate** (56/56 tests passing)
- All core functions available (108.6% coverage across 8 categories)
- Entity indexing creates embeddings automatically  
- Vector search returns relevant results
- AI functions execute and call tools correctly
- Graph database responds to cypher queries with 500+ nodes
- API services respond to ping requests
- AGE extension working correctly with session-level preloading

This testing flow provides comprehensive validation of Percolate's multi-modal AI database capabilities.

## Model-to-SQL Synchronization

### Important Build Step

The Percolate system generates SQL table definitions from Pydantic models. This is a crude migration system that must be run occasionally to keep the database schema in sync with the Python models.

### When to Run Bootstrap

You MUST regenerate SQL files when:

- Modifying any Pydantic model fields (especially type changes like `str` → `UUID`)
- Adding new models to `CORE_INSTALL_MODELS` in `/clients/python/percolate/percolate/models/__init__.py`
- Before building Docker images or deploying to production
- When you encounter SQL/Pydantic type mismatch errors

### How to Run Bootstrap

```bash
# Navigate to Python client directory
cd clients/python/percolate

# Regenerate SQL files from Pydantic models
poetry run python -c "from percolate.models import bootstrap; bootstrap(apply=False, root='/path/to/percolate/extension/')"
```

This command regenerates three critical files:

- `extension/sql/01_add_functions.sql` - All PostgreSQL functions from sql-staging
- `extension/sql/02_create_primary.sql` - Primary tables from Pydantic models  
- `extension/sql/03_create_secondary.sql` - Secondary tables and sample data

### Example: PlanModel userid Field Issue

A common issue is when a Pydantic model field type doesn't match the SQL definition:

1. **Symptom**: `ERROR: operator does not exist: uuid = text` during RLS policy creation
2. **Root Cause**: PlanModel had `userid: Optional[str]` instead of `userid: Optional[UUID | str]`
3. **Fix**: Update the model, run bootstrap, restart Docker with fresh volumes

### Bootstrap Workflow

1. Make changes to Pydantic models
2. Run bootstrap to regenerate SQL files
3. Commit both the model changes AND the regenerated SQL files
4. Deploy or restart Docker containers

**Note**: This is a build-time process, not runtime. The generated SQL files are checked into version control and used during Docker container initialization.