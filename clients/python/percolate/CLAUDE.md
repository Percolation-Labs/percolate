# Percolate Python Client Reference

## Build & Run Commands
- Install dependencies: `poetry install`
- Run API server: `uvicorn percolate.api.main:app --port 5000 --reload`
- Run tests: `pytest`
- Run single test: `pytest test_percolate/path/to/test.py::test_function_name -v`
- Skip slow tests: `pytest -m "not slow"`
- Build package: `poetry build`
- CLI command prefix: `p8` (defined in pyproject.toml)

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