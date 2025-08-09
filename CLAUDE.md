# Claude AI Assistant Guidelines for Percolate Development

## Test Organization

Set envs to whatever .e.g if you add an env script like below run tests in that env with poetry
```
source set_res_env.sh && poetry run python -m pytest
```

### Test Directory Structure

All Python tests for the Percolate project MUST be organized in the following structure:

```
/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/test_percolate/
├── unit/           # Unit tests with mocks, no external dependencies
│   ├── api/
│   ├── models/
│   ├── services/
│   └── utils/
└── integration/    # Integration tests requiring real environment/DB/API
    ├── api/
    ├── mcp/
    ├── database/
    └── services/
```

### Test Categories

#### Unit Tests (`/test_percolate/unit/`)
- Pure code tests using mocks and fixtures
- No real database connections
- No real API calls
- No external service dependencies
- Fast execution
- Can run in isolation

Example:
```python
# test_percolate/unit/services/test_model_runner.py
def test_model_runner_initialization():
    """Test ModelRunner initializes with mocked dependencies"""
    with patch('percolate.services.PostgresService'):
        runner = ModelRunner(config=mock_config)
        assert runner is not None
```

#### Integration Tests (`/test_percolate/integration/`)
- Tests that require real environment setup
- Database connectivity tests
- API endpoint tests
- Service integration tests
- May be slower to execute
- Require proper environment configuration

Example:
```python
# test_percolate/integration/database/test_postgres_connection.py
def test_real_database_connection():
    """Test actual PostgreSQL connection and query execution"""
    pg = PostgresService()
    result = pg.execute("SELECT 1")
    assert result[0][0] == 1
```

### Migration Requirements

1. **No loose test files**: All test files currently in the root of `/clients/python/percolate/` must be moved to appropriate subdirectories
2. **Remove stray directories**: The `/Users/sirsh/code/mr_saoirse/percolate/tests/` directory should be reviewed and contents moved to the proper location
3. **Consistent naming**: All test files must start with `test_` prefix
4. **Clear categorization**: Each test must be clearly categorized as unit or integration

### Running Tests

```bash
# Run all tests
pytest test_percolate/

# Run only unit tests
pytest test_percolate/unit/

# Run only integration tests
pytest test_percolate/integration/

# Run with coverage
pytest test_percolate/ --cov=percolate --cov-report=html
```

### Environment Setup for Integration Tests

Integration tests require proper environment configuration:

```bash
# Required for database tests
export P8_PG_HOST=localhost
export P8_PG_PORT=5432
export P8_PG_DATABASE=app
export P8_PG_USER=postgres
export P8_PG_PASSWORD=postgres

# Required for API tests
export P8_API_ENDPOINT=http://localhost:5008
export P8_API_KEY=postgres
```

### Test File Organization Examples

```
test_percolate/
├── unit/
│   ├── api/
│   │   ├── test_auth.py
│   │   └── test_routes.py
│   ├── models/
│   │   ├── test_abstract_model.py
│   │   └── test_pydantic_models.py
│   ├── services/
│   │   ├── test_postgres_service.py  # Mocked
│   │   └── test_model_runner.py      # Mocked
│   └── utils/
│       ├── test_env.py
│       └── test_parsing.py
└── integration/
    ├── api/
    │   ├── test_entity_endpoints.py   # Real API calls
    │   └── test_oauth_flow.py         # Real auth flow
    ├── mcp/
    │   ├── test_mcp_api_mode.py       # Real MCP server
    │   └── test_mcp_tools.py          # Real tool execution
    ├── database/
    │   ├── test_entity_queries.py     # Real DB queries
    │   └── test_rls_policies.py       # Real RLS tests
    └── services/
        ├── test_s3_upload.py          # Real S3 service
        └── test_model_execution.py    # Real model calls
```

## Code Style Guidelines

[Previous code style content remains the same...]

## Documentation Standards

[Previous documentation content remains the same...]

## Testing Best Practices

1. **Isolation**: Unit tests should be completely isolated from external dependencies
2. **Speed**: Unit tests should execute quickly (< 1 second per test)
3. **Reliability**: Integration tests should handle environment variations gracefully
4. **Coverage**: Aim for >80% code coverage with unit tests
5. **Clarity**: Test names should clearly describe what is being tested
6. **Fixtures**: Use pytest fixtures for common test setup
7. **Markers**: Use pytest markers to categorize tests (e.g., @pytest.mark.slow)

## Common Pitfalls to Avoid

1. Don't mix unit and integration tests in the same file
2. Don't rely on test execution order
3. Don't leave test files in the root directory
4. Don't hardcode environment-specific values in tests
5. Don't skip cleanup in integration tests

## Test Documentation

Each test module should include:
- Module docstring explaining what is being tested
- Clear test function names following pattern: `test_<what>_<condition>_<expected_result>`
- Docstrings for complex test scenarios
- Comments explaining non-obvious test setup