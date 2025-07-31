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
        description="A detailed natural language query for semantic search. Be specific and descriptive to get the best results. Examples: 'machine learning models for customer churn prediction', 'data processing pipelines for financial transactions', 'security policies for user authentication'. When searching within a specific entity type via entity_name, use an empty string '' to list all instances."
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
        description="""Search for entities in the Percolate knowledge base using powerful semantic search. 

**IMPORTANT**: If you're looking for a single specific entity by name or key (e.g., "KT-2011", "MyModel", "DataProcessor"), use the `get_entity` tool instead - it's faster and supports fuzzy matching for variations.

This tool is best for:

1. **Semantic search across all entities**: Use the 'query' parameter with a detailed natural language description
   - The more specific and descriptive your query, the better the results
   - Example: query="machine learning models that predict customer behavior using transaction history"
   - Example: query="data quality validation rules for email addresses and phone numbers"

2. **Search within a specific entity type**: Use 'entity_name' to search instances of a specific entity
   - Example: entity_name="public.Tasks" with query="" lists all task instances
   - Example: entity_name="p8.Agent" with query="" lists all agent definitions
   - Example: entity_name="p8.Model" with query="classification models for fraud detection"
   
**Pro tip**: To discover available entity types, search for 'p8.Agent' first. This returns all registered entity types in the system, which you can then use as the entity_name parameter for targeted searches.

**Common entity types**:
- p8.Agent: All registered entity type definitions
- public.Tasks: Task management entities
- p8.Model: AI model configurations
- p8.Function: Available functions/tools

The search uses advanced semantic understanding to find relevant entities based on meaning, not just keywords.""",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": True},
            "tags": ["entity", "search", "knowledge-base", "query", "discover"]
        }
    )
    async def entity_search(params: EntitySearchParams) -> List[Dict[str, Any]]:
        """Search entities and return raw results"""
        # Check if query is a single term (no spaces, short) - better suited for get_entity
        query_stripped = params.query.strip()
        if (query_stripped and 
            ' ' not in query_stripped and 
            len(query_stripped) <= 50 and 
            not params.entity_name and 
            not params.filters):
            # Single term - use get_entity for better fuzzy matching
            try:
                entity_result = await repository.get_entity(
                    entity_name=query_stripped,
                    entity_type=None,
                    allow_fuzzy_match=True,
                    similarity_threshold=0.3
                )
                # Return as a list to match expected return type
                if entity_result:
                    return [entity_result]
                else:
                    return []
            except:
                # If get_entity fails, fall back to search
                pass
        
        # Regular semantic search
        filters = params.filters or {}
        if params.entity_name:
            filters['entity_name'] = params.entity_name
        
        return await repository.search_entities(
            params.query,
            filters if filters else None,
            params.limit
        )