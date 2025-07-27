"""Function search and evaluation tools for MCP"""

from typing import Optional, Dict, Any, List
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository
import logging

logger = logging.getLogger(__name__)


class FunctionSearchParams(BaseModel):
    """Parameters for function_search tool"""
    query: str = Field(
        ...,
        description="Search query to find matching functions (e.g., 'web search', 'calculate', 'entity')"
    )
    limit: int = Field(
        10,
        description="Maximum number of results to return",
        ge=1,
        le=100
    )


class FunctionEvalParams(BaseModel):
    """Parameters for function_eval tool"""
    function_name: str = Field(
        ...,
        description="Exact name of the function to evaluate"
    )
    args: Dict[str, Any] = Field(
        ...,
        description="JSON arguments to pass to the function, matching the function's parameter schema"
    )


def create_function_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create function-related MCP tools"""
    
    @mcp.tool(
        name="function_search",
        description="Search for available functions/tools in Percolate using the Function model repository",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": True},
            "tags": ["function", "tool", "search", "discovery"]
        }
    )
    async def function_search(params: FunctionSearchParams) -> List[Dict[str, Any]]:
        """Search functions using repository and return raw results"""
        results = await repository.search_functions(params.query, params.limit)
        logger.debug(f"Function search tool returning: {type(results)} - {results}")
        return results
    
    @mcp.tool(
        name="function_eval",
        description="Evaluate/execute a specific function by name with provided arguments",
        annotations={
            "hint": {"readOnlyHint": False, "idempotentHint": False},
            "tags": ["function", "tool", "evaluate", "execute", "run"]
        }
    )
    async def function_eval(params: FunctionEvalParams) -> Dict[str, Any]:
        """Evaluate a function and return raw result"""
        return await repository.evaluate_function(params.function_name, params.args)