# API Integration Tests

This directory contains integration tests for the Percolate API functionality.

## Main Test Files

### test_api_repository_consolidated.py
Consolidated test suite for all API repository functionality including:
- Authentication and ping
- Entity lookup (p8.Agent)
- Fuzzy entity search
- Entity search with filters
- Function search
- Default agent testing
- Help system
- File upload
- Resource search
- Function evaluation

## Running the Tests

### Prerequisites
Set the following environment variables:

```bash
export P8_TEST_BEARER_TOKEN="your-bearer-token"
export P8_TEST_DOMAIN="https://p8.resmagic.io"
export X_User_Email="test@percolate.com"
export P8_DEFAULT_AGENT="p8-Agent"
```

### Run with pytest
```bash
pytest test_api_repository_consolidated.py -v
```

### Run directly
```bash
python test_api_repository_consolidated.py
```

## Other Test Files

- `agent_tests/` - Contains agent-specific integration tests
- `test_memory_api.py` - Tests for memory API functionality

## Notes

- The consolidated test file replaces multiple individual test files that were previously scattered across the codebase
- Tests use the APIProxyRepository class from `percolate.api.mcp_server.api_repository`
- All tests are designed to work with a live API endpoint
- Some tests may show warnings for missing database tables - this is expected in certain environments