"""Help tools using PercolateAgent for knowledge base access"""

from typing import Optional
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository


class HelpParams(BaseModel):
    """Parameters for help tool"""
    query: str = Field(
        ...,
        description="The help query or question to ask the PercolateAgent"
    )
    context: Optional[str] = Field(
        None,
        description="Additional context to help the agent understand and answer the query more accurately"
    )
    max_depth: int = Field(
        3,
        description="Maximum recursion depth for agent operations when searching for answers",
        ge=1,
        le=10
    )


def create_help_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create help-related MCP tools"""
    
    @mcp.tool(
        name="help",
        description="Get help using PercolateAgent to search the knowledge base and provide contextual assistance",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": False},
            "tags": ["help", "assistance", "knowledge", "agent", "qa"]
        }
    )
    async def help(params: HelpParams) -> str:
        """Get help from PercolateAgent and return raw response"""
        return await repository.get_help(
            params.query,
            params.context,
            params.max_depth
        )