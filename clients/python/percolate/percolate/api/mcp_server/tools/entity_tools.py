"""Entity management tools for MCP"""

from typing import Optional, Dict, Any, List
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository


class GetEntityParams(BaseModel):
    """Parameters for get_entity tool"""
    entity_name: str = Field(
        ...,
        description="The name of the entity to retrieve (e.g., 'MyModel', 'DataProcessor', 'AnalysisAgent'). Use the exact casing as provided by the user - fuzzy matching will handle variations automatically."
    )
    entity_type: Optional[str] = Field(
        None,
        description="Optional entity type (e.g., 'Model', 'Dataset', 'Agent') for faster lookup"
    )
    allow_fuzzy_match: bool = Field(
        True,
        description="If True, uses fuzzy matching to find similar entity names when exact match fails. Useful for slight misspellings or case variations (e.g., 'kt-2011' will find 'KT-2011')"
    )
    similarity_threshold: float = Field(
        0.3,
        description="Threshold for fuzzy matching (0.0 to 1.0). Lower values are more permissive and will match more variations",
        ge=0.0,
        le=1.0
    )


class EntitySearchParams(BaseModel):
    """Parameters for entity_search tool"""
    query: str = Field(
        ...,
        description="Search query string to find matching entities. Can be a search term, or an entity type name (e.g., 'p8.Agent', 'public.Tasks') to list all instances of that entity"
    )
    entity_name: Optional[str] = Field(
        None,
        description="Optional entity type name to search within (e.g., 'p8.Agent', 'public.Tasks'). When provided, searches for instances of this specific entity type. Use 'p8.Agent' to find all registered entity types in the system."
    )
    filters: Optional[Dict[str, Any]] = Field(
        None,
        description="Optional filters to narrow search results (e.g., {'type': 'Model', 'tags': ['ml'], 'status': 'active'})"
    )
    limit: int = Field(
        10,
        description="Maximum number of results to return",
        ge=1,
        le=100
    )


def create_entity_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create entity-related MCP tools"""
    
    @mcp.tool(
        name="get_entity",
        description="Retrieve a specific entity by name from the Percolate knowledge base. Supports fuzzy matching by default to handle case variations and slight misspellings (e.g., 'kt-2011' will find 'KT-2011'). Use the exact casing as provided by the user - fuzzy matching handles variations automatically.",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": True},
            "tags": ["entity", "retrieve", "knowledge-base", "fuzzy-matching"]
        }
    )
    async def get_entity(params: GetEntityParams) -> Dict[str, Any]:
        """Get entity by name and return raw result"""
        return await repository.get_entity(
            params.entity_name, 
            params.entity_type, 
            params.allow_fuzzy_match, 
            params.similarity_threshold
        )
    
    @mcp.tool(
        name="entity_search",
        description="""Search for entities in the Percolate knowledge base. This tool has two main modes:

1. **Search across all entities**: Use the 'query' parameter to search across all entity types
   - Example: query="customer data" finds all entities related to customer data

2. **Search within a specific entity type**: Use 'entity_name' to search instances of a specific entity
   - Example: entity_name="public.Tasks" finds all task instances
   - Example: entity_name="p8.Agent" finds all agent definitions
   
**Pro tip**: To discover available entity types, search for 'p8.Agent' first. This returns all registered entity types in the system, which you can then use as the entity_name parameter for targeted searches.

**Common entity types**:
- p8.Agent: All registered entity type definitions
- public.Tasks: Task management entities
- p8.Model: AI model configurations
- p8.Function: Available functions/tools

The search supports filters for additional refinement.""",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": True},
            "tags": ["entity", "search", "knowledge-base", "query", "discover"]
        }
    )
    async def entity_search(params: EntitySearchParams) -> List[Dict[str, Any]]:
        """Search entities and return raw results"""
        # If entity_name is provided, add it to filters
        filters = params.filters or {}
        if params.entity_name:
            filters['entity_name'] = params.entity_name
        
        return await repository.search_entities(
            params.query,
            filters if filters else None,
            params.limit
        )