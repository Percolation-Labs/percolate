# Percolate Python Client Reference

## Build & Run Commands
- Install dependencies: `poetry install`
- Run API server: `uvicorn percolate.api.main:app --port 5000 --reload`
- Run tests: `pytest`
- Run single test: `pytest test_percolate/path/to/test.py::test_function_name -v`
- Skip slow tests: `pytest -m "not slow"`
- Build package: `poetry build`
- CLI command prefix: `p8` (defined in pyproject.toml)

## Database Connection Settings for Testing

When testing with the database on port 15432, always set the following environment variables:

```bash
# Set the test database port
export P8_PG_PORT=15432

# Set the test database password from the P8_TEST_BEARER_TOKEN
export P8_PG_PASSWORD=$P8_TEST_BEARER_TOKEN
```

These settings ensure that:
1. The PostgreSQL connection uses port 15432 instead of the default port 5438
2. The password is set correctly using the P8_TEST_BEARER_TOKEN

### Example Connection Code

```python
import os
import percolate as p8
from percolate.services import PostgresService

# Verify the correct environment variables are set
print(f"Using database port: {os.environ.get('P8_PG_PORT', '5438')} (should be 15432)")
print(f"Database password is {'set' if os.environ.get('P8_PG_PASSWORD') else 'NOT SET'}")

# The connection string is automatically built using these environment variables
pg = PostgresService()
print(f"Connection string: {pg._connection_string}")

# Test the connection
test_query = pg.execute("SELECT 1 as connection_test")
if test_query and test_query[0]['connection_test'] == 1:
    print("✅ Database connection successful!")
```

Always run these checks before interacting with the database for testing.

### Model Registration for sync module

When registering the sync models, they must be registered in the `p8` schema, not in a separate `sync` schema:

```python
from percolate.models.sync import register_sync_models

# Register models (creates tables in the p8 schema)
results = register_sync_models()
```

For testing, use the provided test script:

```bash
# Set environment variables and run test
export P8_PG_PORT=15432
export P8_PG_PASSWORD=$P8_TEST_BEARER_TOKEN
python -m percolate.models.sync.test_connection
```

The test_connection.py script will verify:
1. Database connectivity to port 15432
2. Successful model registration in the p8 schema

## Code Style Guidelines

### Imports
- Standard library imports first
- Third-party imports second
- Local module imports last
- Use absolute imports from the percolate package

### Type Annotations
- Use Python type hints consistently (`typing` module)
- Use Union types with `|` syntax for Python 3.10+ (e.g., `str | None`)
- Document parameter and return types in docstrings

### Naming Conventions
- Classes: PascalCase
- Methods/Functions: snake_case
- Variables: snake_case
- Constants: UPPER_SNAKE_CASE

### Error Handling
- Use try/except blocks with specific exception types
- Log errors with loguru
- Use tenacity for retries where appropriate

### Documentation
- Use docstrings for all public classes and methods
- Follow Google-style docstring format with param/return descriptions
- Include examples where helpful

### Models
- Extend AbstractModel for entity models
- Use Pydantic for data validation and serialization
- Define model namespace and configuration in model_config