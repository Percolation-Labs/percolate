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
- Home page in percolate/home/

## About Percolate
Percolate is an agentic AI system built on a multimodal database architecture. It focuses on:

- **Agentic Memory**: Creating persistent, context-aware knowledge representations that agents can access and update
- **Multimodal Data Handling**: Supporting diverse data types (text, structured data, images) in a unified system
- **Personalization**: Adapting to individual users by learning from interactions and query patterns
- **Knowledge Systems**: Building sophisticated information systems with semantic understanding and reasoning capabilities

The platform is designed to enable the development of intelligent, adaptive, and personalized AI systems that improve over time through interaction.