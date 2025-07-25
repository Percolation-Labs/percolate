# Integration Tests

This directory contains integration tests that:
- Require real environment setup (database, API, services)
- Test actual system behavior end-to-end
- May take longer to execute
- Require proper configuration
- Test real interactions between components

## Environment Setup

Integration tests require proper environment configuration:

```bash
# Database configuration
export P8_PG_HOST=localhost
export P8_PG_PORT=5432
export P8_PG_DATABASE=app
export P8_PG_USER=postgres
export P8_PG_PASSWORD=postgres

# API configuration
export P8_API_ENDPOINT=http://localhost:5008
export P8_API_KEY=postgres
export X-User-Email=test@example.com

# MCP configuration
export P8_USE_API_MODE=true  # or false for database mode
```

## Running Integration Tests

```bash
# Run all integration tests
pytest test_percolate/integration/

# Run specific category
pytest test_percolate/integration/api/
pytest test_percolate/integration/mcp/
pytest test_percolate/integration/database/
pytest test_percolate/integration/services/

# Run with markers
pytest test_percolate/integration/ -m "not slow"
```

## Test Categories

- `api/` - API endpoint tests with real HTTP requests
- `mcp/` - MCP server tests with real connections
- `database/` - Database tests with real queries and transactions
- `services/` - Service integration tests with real external services

## Prerequisites

1. PostgreSQL database running and accessible
2. Percolate API server running (for API tests)
3. Required environment variables set
4. S3/Minio available (for storage tests)
5. Network connectivity (for external service tests)

## Writing Integration Tests

Example integration test:

```python
import pytest
import percolate as p8

@pytest.mark.integration
def test_real_database_query():
    """Test actual database query execution"""
    pg = p8.PostgresService()
    pg.connect()
    
    result = pg.execute("SELECT * FROM p8.Agent LIMIT 1")
    assert len(result) >= 0
    
    pg.close()
```

## Cleanup

Integration tests should always clean up after themselves:
- Delete test data created during tests
- Close connections properly
- Reset any modified state