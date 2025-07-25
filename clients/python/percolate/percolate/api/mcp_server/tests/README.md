# Percolate MCP Server Tests

## Test Structure

- `test_auth.py` - Unit tests for authentication (mocked)
- `test_entity_tools.py` - Unit tests for entity tools (mocked)
- `test_function_tools.py` - Unit tests for function tools (mocked)
- `test_help_tools.py` - Unit tests for help tools (mocked)
- `test_integration.py` - Integration tests using real Percolate backend

## Running Tests

### Unit Tests Only (No Backend Required)

```bash
pytest percolate/api/mcp_server/tests/ -k "not integration"
```

### Integration Tests (Requires Backend)

Set up environment variables:

```bash
export P8_API_KEY="your-api-key"
export P8_USER_ID="test-user"  # optional, defaults to system user
export P8_USER_GROUPS="group1,group2"  # optional
export P8_ROLE_LEVEL="1"  # optional, 1=admin
```

Run integration tests:

```bash
pytest percolate/api/mcp_server/tests/test_integration.py
```

### All Tests

```bash
pytest percolate/api/mcp_server/tests/
```

### Skip Slow Tests

```bash
pytest percolate/api/mcp_server/tests/ -m "not slow"
```

## Test Coverage

```bash
pytest --cov=percolate.api.mcp_server tests/
```

## Notes

- Integration tests are automatically skipped if `P8_API_KEY` is not set
- The integration tests assume a running Percolate backend
- Some integration tests may depend on specific data existing in your Percolate instance
- Adjust test entity IDs and queries based on your test data