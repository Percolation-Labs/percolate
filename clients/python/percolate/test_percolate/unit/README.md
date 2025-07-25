# Unit Tests

This directory contains unit tests that:
- Use mocks and fixtures instead of real services
- Do not require database connections
- Do not make real API calls
- Can run in complete isolation
- Execute quickly (< 1 second per test)

## Running Unit Tests

```bash
# Run all unit tests
pytest test_percolate/unit/

# Run specific category
pytest test_percolate/unit/api/
pytest test_percolate/unit/models/
pytest test_percolate/unit/services/

# Run with coverage
pytest test_percolate/unit/ --cov=percolate --cov-report=html
```

## Test Structure

- `api/` - Unit tests for API routes and controllers (mocked dependencies)
- `models/` - Unit tests for data models and schemas
- `services/` - Unit tests for service classes (mocked external calls)
- `utils/` - Unit tests for utility functions
- `mcp/` - Unit tests for MCP server components (mocked)

## Writing Unit Tests

Example unit test with mocks:

```python
from unittest.mock import Mock, patch
import pytest

def test_service_with_mocked_db():
    """Test service behavior with mocked database"""
    with patch('percolate.services.PostgresService') as mock_pg:
        mock_pg.return_value.execute.return_value = [{'id': 1}]
        
        service = MyService()
        result = service.get_data()
        
        assert result == [{'id': 1}]
        mock_pg.return_value.execute.assert_called_once()
```