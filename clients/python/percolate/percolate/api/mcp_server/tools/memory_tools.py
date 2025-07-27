"""Memory management tools for MCP"""

from typing import Optional, Dict, Any, List
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository
from percolate.models.p8.types import UserMemory
from percolate.api.controllers.memory import user_memory_controller
import logging

logger = logging.getLogger(__name__)


class AddMemoryParams(BaseModel):
    """Parameters for add_memory tool"""
    user_id: str = Field(
        ...,
        description="User ID (email) to associate the memory with"
    )
    content: str = Field(
        ...,
        description="The memory content to store"
    )
    name: Optional[str] = Field(
        None,
        description="Optional name for the memory (auto-generated if not provided)"
    )
    category: Optional[str] = Field(
        None,
        description="Optional category (defaults to 'user_memory')"
    )
    metadata: Optional[Dict[str, Any]] = Field(
        None,
        description="Optional metadata dictionary"
    )


class ListMemoriesParams(BaseModel):
    """Parameters for list_memories tool"""
    user_id: str = Field(
        ...,
        description="User ID to list memories for"
    )
    limit: int = Field(
        default=50,
        description="Maximum number of memories to return",
        ge=1,
        le=200
    )
    offset: int = Field(
        default=0,
        description="Number of memories to skip",
        ge=0
    )


class GetMemoryParams(BaseModel):
    """Parameters for get_memory tool"""
    user_id: str = Field(
        ...,
        description="User ID that owns the memory"
    )
    name: str = Field(
        ...,
        description="Name of the memory to retrieve"
    )


class SearchMemoriesParams(BaseModel):
    """Parameters for search_memories tool"""
    user_id: str = Field(
        ...,
        description="User ID to search memories for"
    )
    query: Optional[str] = Field(
        None,
        description="Search query for memory content"
    )
    category: Optional[str] = Field(
        None,
        description="Filter by category"
    )
    limit: int = Field(
        default=50,
        description="Maximum number of results",
        ge=1,
        le=200
    )


def create_memory_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create memory-related MCP tools"""
    
    @mcp.tool(
        name="add_memory",
        description="Add a new memory for a user"
    )
    async def add_memory(params: AddMemoryParams) -> Dict[str, Any]:
        """Add a new memory for a user"""
        try:
            memory = await user_memory_controller.add(
                user_id=params.user_id,
                content=params.content,
                name=params.name,
                category=params.category,
                metadata=params.metadata
            )
            
            return {
                "id": str(memory.id),
                "name": memory.name,
                "content": memory.content,
                "category": memory.category,
                "metadata": memory.metadata or {},
                "userid": memory.userid,
                "created_at": memory.created_at.isoformat() if memory.created_at else None
            }
        except Exception as e:
            logger.error(f"Error adding memory: {str(e)}", exc_info=True)
            return {"error": str(e)}
    
    @mcp.tool(
        name="list_memories",
        description="List recent memories for a user"
    )
    async def list_memories(params: ListMemoriesParams) -> List[Dict[str, Any]]:
        """List recent memories for a user"""
        try:
            memories = await user_memory_controller.list_recent(
                user_id=params.user_id,
                limit=params.limit,
                offset=params.offset
            )
            
            return [
                {
                    "id": str(memory.id),
                    "name": memory.name,
                    "content": memory.content,
                    "category": memory.category,
                    "metadata": memory.metadata or {},
                    "userid": memory.userid,
                    "created_at": memory.created_at.isoformat() if memory.created_at else None,
                    "updated_at": memory.updated_at.isoformat() if memory.updated_at else None
                }
                for memory in memories
            ]
        except Exception as e:
            logger.error(f"Error listing memories: {str(e)}", exc_info=True)
            return [{"error": str(e)}]
    
    @mcp.tool(
        name="get_memory",
        description="Get a specific memory by name"
    )
    async def get_memory(params: GetMemoryParams) -> Dict[str, Any]:
        """Get a specific memory by name"""
        try:
            memory = await user_memory_controller.get(
                user_id=params.user_id,
                name=params.name
            )
            
            return {
                "id": str(memory.id),
                "name": memory.name,
                "content": memory.content,
                "category": memory.category,
                "metadata": memory.metadata or {},
                "userid": memory.userid,
                "created_at": memory.created_at.isoformat() if memory.created_at else None,
                "updated_at": memory.updated_at.isoformat() if memory.updated_at else None
            }
        except Exception as e:
            logger.error(f"Error getting memory: {str(e)}", exc_info=True)
            return {"error": str(e)}
    
    @mcp.tool(
        name="search_memories",
        description="Search memories by content or category"
    )
    async def search_memories(params: SearchMemoriesParams) -> List[Dict[str, Any]]:
        """Search memories by content or category"""
        try:
            memories = await user_memory_controller.search(
                user_id=params.user_id,
                query=params.query,
                category=params.category,
                limit=params.limit
            )
            
            return [
                {
                    "id": str(memory.id),
                    "name": memory.name,
                    "content": memory.content,
                    "category": memory.category,
                    "metadata": memory.metadata or {},
                    "userid": memory.userid,
                    "created_at": memory.created_at.isoformat() if memory.created_at else None,
                    "updated_at": memory.updated_at.isoformat() if memory.updated_at else None
                }
                for memory in memories
            ]
        except Exception as e:
            logger.error(f"Error searching memories: {str(e)}", exc_info=True)
            return [{"error": str(e)}]
    
    return mcp