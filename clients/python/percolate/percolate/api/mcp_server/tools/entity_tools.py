"""Entity management tools for MCP"""

from typing import Optional, Dict, Any, List
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository


class GetEntityParams(BaseModel):
    """Parameters for get_entity tool"""
    entity_name: str = Field(
        ...,
        description="The name of the entity to retrieve (e.g., 'MyModel', 'DataProcessor', 'AnalysisAgent')"
    )
    entity_type: Optional[str] = Field(
        None,
        description="Optional entity type (e.g., 'Model', 'Dataset', 'Agent') for faster lookup"
    )


class EntitySearchParams(BaseModel):
    """Parameters for entity_search tool"""
    query: str = Field(
        ...,
        description="Search query string to find matching entities"
    )
    filters: Optional[Dict[str, Any]] = Field(
        None,
        description="Optional filters to narrow search results (e.g., {'type': 'Model', 'tags': ['ml']})"
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
        description="Retrieve a specific entity by name from the Percolate knowledge base",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": True},
            "tags": ["entity", "retrieve", "knowledge-base"]
        }
    )
    async def get_entity(params: GetEntityParams) -> Dict[str, Any]:
        """Get entity by name and return raw result"""
        return await repository.get_entity(params.entity_name, params.entity_type)
    
    @mcp.tool(
        name="entity_search",
        description="Search for entities in the Percolate knowledge base using query and filters",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": True},
            "tags": ["entity", "search", "knowledge-base", "query"]
        }
    )
    async def entity_search(params: EntitySearchParams) -> List[Dict[str, Any]]:
        """Search entities and return raw results"""
        return await repository.search_entities(
            params.query,
            params.filters,
            params.limit
        )