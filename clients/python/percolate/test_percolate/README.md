# Percolate Test Suite

This directory contains all tests for the Percolate Python client, organized into unit and integration tests.

## Directory Structure

```
test_percolate/
├── unit/               # Fast, isolated tests with mocks
│   ├── api/           # API route unit tests
│   ├── models/        # Model validation tests
│   ├── services/      # Service logic tests (mocked)
│   ├── utils/         # Utility function tests
│   └── mcp/           # MCP server unit tests
└── integration/        # Tests requiring real environment
    ├── api/           # Real API endpoint tests
    ├── mcp/           # MCP server integration tests
    ├── database/      # Database connectivity tests
    └── services/      # Service integration tests
```

## Quick Start

```bash
# Run all tests
pytest

# Run only unit tests (fast)
pytest test_percolate/unit/

# Run only integration tests (requires environment)
pytest test_percolate/integration/

# Run with coverage report
pytest --cov=percolate --cov-report=html

# Run specific test file
pytest test_percolate/unit/models/test_AbstractModel.py

# Run tests matching pattern
pytest -k "test_user_context"

# Run tests with specific marker
pytest -m "not slow"
```

## Test Categories

### Unit Tests
- No external dependencies
- Use mocks for all I/O operations
- Fast execution (< 1 second per test)
- Can run anywhere without setup

### Integration Tests  
- Require configured environment
- Test real service interactions
- May be slower to execute
- Verify end-to-end functionality

## Environment Setup

See `integration/README.md` for required environment configuration.

## Writing Tests

### Unit Test Example
```python
# test_percolate/unit/services/test_example.py
from unittest.mock import Mock, patch
import pytest

class TestExampleService:
    def test_process_data_with_mock(self):
        with patch('percolate.services.PostgresService') as mock_db:
            mock_db.return_value.execute.return_value = [{'id': 1}]
            
            service = ExampleService()
            result = service.process()
            
            assert result == expected_value
            mock_db.return_value.execute.assert_called_once()
```

### Integration Test Example
```python
# test_percolate/integration/database/test_example.py
import pytest
import percolate as p8

@pytest.mark.integration
class TestDatabaseIntegration:
    def test_real_query(self):
        pg = p8.PostgresService()
        result = pg.execute("SELECT 1")
        assert result[0][0] == 1
```

## Test Markers

We use pytest markers to categorize tests:

- `@pytest.mark.unit` - Unit tests (default)
- `@pytest.mark.integration` - Integration tests
- `@pytest.mark.slow` - Tests that take > 5 seconds
- `@pytest.mark.requires_db` - Tests requiring database
- `@pytest.mark.requires_api` - Tests requiring API server

## Coverage Goals

- Unit tests: > 80% code coverage
- Integration tests: Cover all critical paths
- Combined: > 90% total coverage

## CI/CD Integration

```yaml
# Example GitHub Actions workflow
test:
  runs-on: ubuntu-latest
  steps:
    - name: Run unit tests
      run: pytest test_percolate/unit/
    
    - name: Run integration tests
      if: github.event_name == 'push'
      run: pytest test_percolate/integration/
      env:
        P8_PG_HOST: ${{ secrets.TEST_DB_HOST }}
        P8_API_KEY: ${{ secrets.TEST_API_KEY }}
```

## Troubleshooting

### Common Issues

1. **Import errors**: Ensure you're running from the project root
2. **Database connection failed**: Check environment variables
3. **API tests failing**: Ensure API server is running
4. **Slow tests**: Use `-m "not slow"` to skip slow tests

### Debug Mode

```bash
# Run with verbose output
pytest -vv

# Show print statements
pytest -s

# Debug specific test
pytest --pdb test_percolate/unit/models/test_example.py::test_specific
```