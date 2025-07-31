"""Memory management tools for MCP"""

from typing import Optional, Dict, Any, List
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository
from ..utils import format_error_response
from ..exceptions import ValidationError, RepositoryError
import logging

logger = logging.getLogger(__name__)

# Local UserMemory model definition (cloned from schema)
class UserMemory(BaseModel):
    """User memory model for MCP operations"""
    id: Optional[str] = Field(None, description="Unique identifier for the memory")
    name: str = Field(..., description="Name/title of the memory")
    content: str = Field(..., description="Main content of the memory")
    category: Optional[str] = Field(None, description="Category for organizing memories")
    userid: str = Field(..., description="User ID who owns this memory")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Additional metadata")
    resource_timestamp: Optional[str] = Field(None, description="Timestamp when memory was created")


class AddMemoryParams(BaseModel):
    """Parameters for add_memory tool"""
    content: str = Field(
        ...,
        description="The main memory content to store - can be text, notes, facts, or any information you want to remember"
    )
    name: Optional[str] = Field(
        None,
        description="Optional unique name for the memory. If not provided, will be auto-generated from content"
    )
    category: Optional[str] = Field(
        None,
        description="Optional category to organize memories (e.g., 'personal', 'work', 'learning'). Defaults to 'user_memory'"
    )
    metadata: Optional[Dict[str, Any]] = Field(
        None,
        description="Optional metadata dictionary for additional structured information (tags, timestamps, sources, etc.)"
    )


class ListMemoriesParams(BaseModel):
    """Parameters for list_memories tool"""
    limit: int = Field(
        default=50,
        description="Maximum number of memories to return (1-200). Use smaller values for focused results",
        ge=1,
        le=200
    )
    offset: int = Field(
        default=0,
        description="Number of memories to skip for pagination. Use with limit to get specific pages of results",
        ge=0
    )


class GetMemoryParams(BaseModel):
    """Parameters for get_memory tool"""
    name: str = Field(
        ...,
        description="Exact name of the memory to retrieve. Memory names are unique per user"
    )


class SearchMemoriesParams(BaseModel):
    """Parameters for search_memories tool"""
    query: Optional[str] = Field(
        None,
        description="Search query to find memories by content using semantic search. Can be keywords, phrases, or questions"
    )
    category: Optional[str] = Field(
        None,
        description="Filter results to only memories in this specific category"
    )
    limit: int = Field(
        default=50,
        description="Maximum number of search results to return (1-200)",
        ge=1,
        le=200
    )




class BuildMemoryParams(BaseModel):
    """Parameters for build_memory tool"""
    pass  # No parameters needed - analyzes all memories for the authenticated user


def create_memory_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create memory-related MCP tools"""
    
    @mcp.tool(
        name="add_memory",
        description="Store a new memory with content, optional name, category, and metadata. Memories are automatically associated with the authenticated user."
    )
    async def add_memory(params: AddMemoryParams) -> Dict[str, Any]:
        """Add a new memory for a user"""
        try:
            result = await repository.add_memory(
                content=params.content,
                name=params.name,
                category=params.category,
                metadata=params.metadata
            )
            return result
        except Exception as e:
            logger.error(f"Error adding memory: {str(e)}")
            logger.exception("Full traceback:")
            return format_error_response(e)
    
    @mcp.tool(
        name="list_memories",
        description="Retrieve a paginated list of recent memories for the authenticated user, ordered by most recently updated."
    )
    async def list_memories(params: ListMemoriesParams) -> List[Dict[str, Any]]:
        """List recent memories for a user"""
        try:
            memories = await repository.list_memories(
                limit=params.limit,
                offset=params.offset
            )
            return memories
        except Exception as e:
            logger.error(f"Error listing memories: {str(e)}")
            logger.exception("Full traceback:")
            raise RepositoryError(f"Failed to list memories: {str(e)}", operation="list_memories")
    
    @mcp.tool(
        name="get_memory",
        description="Retrieve a specific memory by its name for the authenticated user."
    )
    async def get_memory(params: GetMemoryParams) -> Dict[str, Any]:
        """Get a specific memory by name"""
        try:
            result = await repository.get_memory(
                name=params.name
            )
            return result
        except Exception as e:
            logger.error(f"Error getting memory: {str(e)}")
            logger.exception("Full traceback:")
            return format_error_response(e)
    
    @mcp.tool(
        name="search_memories",
        description="Search through memories using semantic search on content, optionally filtered by category."
    )
    async def search_memories(params: SearchMemoriesParams) -> List[Dict[str, Any]]:
        """Search memories by content or category"""
        try:
            memories = await repository.search_memories(
                query=params.query,
                category=params.category,
                limit=params.limit
            )
            return memories
        except Exception as e:
            logger.error(f"Error searching memories: {str(e)}")
            logger.exception("Full traceback:")
            return [format_error_response(e)]
    
    
    @mcp.tool(
        name="build_memory",
        description="Build and analyze memory patterns, connections, and summaries for the authenticated user (placeholder for future AI-powered memory analysis)."
    )
    async def build_memory(params: BuildMemoryParams) -> Dict[str, Any]:
        """Build memory summary for the authenticated user"""
        try:
            result = await repository.build_memory()
            return result
        except Exception as e:
            logger.error(f"Error building memory: {str(e)}")
            logger.exception("Full traceback:")
            return format_error_response(e)
    
    return mcp