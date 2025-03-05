# Percolate Python Client Commands and Guidelines

## Build & Run Commands
- Install dependencies: `poetry install`
- Run API server: `uvicorn percolate.api.main:app --port 5000 --reload`
- Run CLI: `python percolate/cli.py`
- Run tests: `pytest .` (all tests) or `pytest test_percolate/path/to/test_file.py::test_function` (single test)
- Sync model keys: `python percolate/cli.py add env --sync`
- Index codebase: `python percolate/cli.py index`

## Code Style Guidelines
- **Imports**: Group stdlib first, then third-party, then local imports
- **Types**: Use type hints with Python 3.10+ syntax (union with `|` operator)
- **Naming**: 
  - Classes: PascalCase
  - Functions/variables: snake_case
  - Constants: UPPER_SNAKE_CASE
- **Error handling**: Use appropriate try/except blocks with specific exceptions
- **Documentation**: Include docstrings for classes and functions
- **Models**: Use Pydantic for data models with appropriate Field annotations
- **Environment**: Use env.py for environment variable access

## Project Structure
- API endpoints in percolate/api/routes/
- Core models in percolate/models/
- Services in percolate/services/
- Utilities in percolate/utils/