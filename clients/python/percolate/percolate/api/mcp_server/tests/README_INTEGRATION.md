# MCP Server Integration Tests

## Overview

These integration tests verify the MCP server functionality using real database connections and the stdio transport mode. The tests use FastMCP client to communicate with the server process.

## Prerequisites

1. **Docker**: Required for running PostgreSQL test database
2. **Python Dependencies**:
   ```bash
   pip install pytest pytest-asyncio docker psycopg2-binary fastmcp
   ```

## Test Structure

### Test Files

- `conftest.py` - Test configuration, fixtures, and database setup
- `test_integration_stdio.py` - Comprehensive integration tests using stdio transport
- `test_integration_http.py` - (Future) HTTP transport integration tests

### Test Categories

1. **Entity Tools Tests** - CRUD operations on entities
2. **Function Tools Tests** - Function discovery and execution
3. **File Tools Tests** - File upload and resource search
4. **Help Tools Tests** - AI-powered assistance
5. **Authentication Tests** - Token validation and user context
6. **Error Handling Tests** - Invalid inputs and edge cases
7. **Concurrency Tests** - Parallel operations
8. **Performance Tests** - Load and response time

## Running Tests

### Basic Test Run

```bash
# Run all integration tests
pytest percolate/api/mcp_server/tests/test_integration_stdio.py -v

# Run specific test class
pytest percolate/api/mcp_server/tests/test_integration_stdio.py::TestEntityToolsStdio -v

# Run specific test
pytest percolate/api/mcp_server/tests/test_integration_stdio.py::TestEntityToolsStdio::test_entity_search_stdio -v
```

### With Custom Database

If you have an existing Percolate database:

```bash
export P8_PG_HOST=localhost
export P8_PG_PORT=5432
export P8_PG_USER=postgres
export P8_PG_PASSWORD=yourpassword
export P8_API_KEY=your-api-key
export P8_USER_EMAIL=test@example.com

pytest percolate/api/mcp_server/tests/test_integration_stdio.py -v
```

### Skip Slow Tests

```bash
pytest percolate/api/mcp_server/tests/test_integration_stdio.py -v -m "not slow"
```

### With Coverage

```bash
pytest percolate/api/mcp_server/tests/test_integration_stdio.py --cov=percolate.api.mcp_server --cov-report=html
```

## Test Database Setup

The tests automatically:

1. Start a PostgreSQL container with pgvector extension
2. Create test database with Percolate schema
3. Insert sample test data
4. Clean up after tests (optional)

### Manual Database Setup

If you prefer to use an existing database:

```sql
-- Required extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;

-- Required schemas
CREATE SCHEMA IF NOT EXISTS p8;
CREATE SCHEMA IF NOT EXISTS p8_embeddings;

-- Basic tables (simplified for testing)
CREATE TABLE p8."Entity" (...);
CREATE TABLE p8."Function" (...);
CREATE TABLE p8."Resource" (...);
```

## Test Data

The fixtures create sample data:

- **Entities**: Test models and datasets
- **Functions**: Echo and search functions
- **Resources**: Test documents and data files

## Debugging Tests

### Enable Debug Logging

```bash
export P8_LOG_LEVEL=DEBUG
pytest percolate/api/mcp_server/tests/test_integration_stdio.py -v -s
```

### Keep Test Database

Edit `conftest.py` and comment out the cleanup section:

```python
# Cleanup (optional - keep for debugging)
# container.stop()
# container.remove()
```

### Interactive Testing

```python
# Start Python with test environment
python -m pytest --pdb percolate/api/mcp_server/tests/test_integration_stdio.py

# In debugger, interact with client
(Pdb) client = await mcp_client_stdio()
(Pdb) result = await client.call_tool("entity_search", {"query": "test"})
(Pdb) print(result)
```

## Common Issues

### Docker Connection Failed

```bash
# Ensure Docker is running
docker ps

# Check Docker permissions
sudo usermod -aG docker $USER
```

### Database Connection Failed

```bash
# Check if test database is running
docker ps | grep percolate-test-db

# Check port availability
netstat -an | grep 5433
```

### MCP Server Not Starting

```bash
# Test server directly
P8_API_KEY=test P8_USER_EMAIL=test@example.com python -m percolate.api.mcp_server
```

### Import Errors

```bash
# Ensure you're in the right directory
cd /path/to/percolate/clients/python

# Install in development mode
pip install -e .
```

## Writing New Tests

### Test Template

```python
class TestNewFeatureStdio:
    """Test new feature via stdio transport"""
    
    @pytest.mark.asyncio
    async def test_new_tool_stdio(self, mcp_client_stdio):
        """Test description"""
        # Arrange
        params = {"param1": "value1"}
        
        # Act
        result = await mcp_client_stdio.call_tool("new_tool", params)
        
        # Assert
        assert isinstance(result, dict)
        assert "expected_field" in result
```

### Adding Fixtures

```python
@pytest.fixture
async def test_data():
    """Create test data"""
    # Setup
    data = create_test_data()
    
    yield data
    
    # Teardown
    cleanup_test_data(data)
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: MCP Integration Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: pgvector/pgvector:pg16
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432
    
    steps:
    - uses: actions/checkout@v3
    - uses: actions/setup-python@v4
      with:
        python-version: '3.10'
    
    - name: Install dependencies
      run: |
        pip install -e .
        pip install pytest pytest-asyncio fastmcp docker
    
    - name: Run integration tests
      env:
        P8_PG_HOST: localhost
        P8_PG_PORT: 5432
        P8_API_KEY: test-key
        P8_USER_EMAIL: test@example.com
      run: |
        pytest percolate/api/mcp_server/tests/test_integration_stdio.py -v
```

## Future Improvements

1. **HTTP Transport Tests**: Test server-mounted MCP endpoint
2. **WebSocket Tests**: Real-time communication tests
3. **Load Testing**: Stress test with multiple clients
4. **Security Tests**: Authentication edge cases
5. **Cross-Platform Tests**: Windows/Mac/Linux compatibility