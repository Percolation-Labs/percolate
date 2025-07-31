"""
API routes for UserMemory management
"""
from typing import List, Optional, Dict, Any
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from percolate.utils import logger

from percolate.api.routes.auth import hybrid_auth
from percolate.api.controllers.memory import user_memory_controller
from percolate.models.p8.types import UserMemory, User
import datetime

router = APIRouter()


class AddMemoryRequest(BaseModel):
    """Request model for adding a new memory"""

    content: str
    name: Optional[str] = None
    category: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None


class MemoryResponse(BaseModel):
    """Response model for memory operations"""

    id: str
    name: str
    content: str
    category: str
    metadata: Dict[str, Any]
    userid: str
    created_at: Optional[str | datetime.datetime] = None
    updated_at: Optional[str | datetime.datetime] = None

    class Config:
        from_attributes = True


class MemoryListResponse(BaseModel):
    """Response model for listing memories"""

    memories: List[MemoryResponse]
    total: int
    offset: int
    limit: int


@router.post("/add", response_model=MemoryResponse)
async def add_memory(
    request: AddMemoryRequest, user_id: Optional[str] = Depends(hybrid_auth)
) -> MemoryResponse:
    """Add a new memory for the current user"""
    if not user_id:
        raise HTTPException(status_code=401, detail="Authentication required")

    try:
        memory = await user_memory_controller.add(
            user_id=user_id,
            content=request.content,
            name=request.name,
            category=request.category,
            metadata=request.metadata,
        )

        return MemoryResponse(
            id=str(memory.id),
            name=memory.name,
            content=memory.content,
            category=memory.category,
            metadata=memory.metadata or {},
            userid=memory.userid,
        )
    except Exception as e:
        logger.error(f"Failed to add memory for user {user_id}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=f"Failed to add memory: {str(e)}")


@router.get("/list", response_model=MemoryListResponse)
async def list_recent_memories(
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    user_id: Optional[str] = Depends(hybrid_auth),
) -> MemoryListResponse:
    """List recent memories for the current user"""
    if not user_id:
        raise HTTPException(status_code=401, detail="Authentication required")

    try:
        memories = await user_memory_controller.list_recent(
            user_id=user_id, limit=limit, offset=offset
        )

        memory_responses = [MemoryResponse(**memory) for memory in memories]

        return MemoryListResponse(
            memories=memory_responses,
            total=len(memory_responses),
            offset=offset,
            limit=limit,
        )
    except Exception as e:
        logger.error(f"Failed to list memories for user {user_id}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(
            status_code=500, detail=f"Failed to list memories: {str(e)}"
        )


@router.get("/get/{name}", response_model=MemoryResponse)
async def get_memory(
    name: str, user_id: Optional[str] = Depends(hybrid_auth)
) -> MemoryResponse:
    """Get a specific memory by name"""
    if not user_id:
        raise HTTPException(status_code=401, detail="Authentication required")

    try:
        memory = await user_memory_controller.get(user_id=user_id, name=name)

        if not memory:
            raise HTTPException(status_code=404, detail=f"Memory '{name}' not found")

        return MemoryResponse(**memory)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get memory '{name}' for user {user_id}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=f"Failed to get memory: {str(e)}")


@router.get("/search", response_model=MemoryListResponse)
async def search_memories(
    query: Optional[str] = Query(default=None),
    category: Optional[str] = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    user_id: Optional[str] = Depends(hybrid_auth),
) -> MemoryListResponse:
    """Search memories by query and/or category"""
    if not user_id:
        raise HTTPException(status_code=401, detail="Authentication required")

    try:
        memories = await user_memory_controller.search(
            user_id=user_id, query=query, category=category, limit=limit
        )

        memory_responses = [
            MemoryResponse(
                id=str(memory.id),
                name=memory.name,
                content=memory.content,
                category=memory.category,
                metadata=memory.metadata or {},
                userid=memory.userid,
                created_at=memory.resource_timestamp.isoformat() if hasattr(memory, 'resource_timestamp') and memory.resource_timestamp else None,
                updated_at=memory.resource_timestamp.isoformat() if hasattr(memory, 'resource_timestamp') and memory.resource_timestamp else None,
            )
            for memory in memories
        ]

        return MemoryListResponse(
            memories=memory_responses,
            total=len(memory_responses),
            offset=0,
            limit=limit,
        )
    except Exception as e:
        logger.error(
            f"Failed to search memories for user {user_id} with query '{query}': {e}"
        )
        logger.exception("Full traceback:")
        raise HTTPException(
            status_code=500, detail=f"Failed to search memories: {str(e)}"
        )


@router.post("/build")
async def build_memories(
    user_id: Optional[str] = Depends(hybrid_auth),
) -> Dict[str, Any]:
    """Build memory summary for the current user (placeholder)"""
    if not user_id:
        raise HTTPException(status_code=401, detail="Authentication required")

    try:
        return await user_memory_controller.build(user_id=user_id)
    except Exception as e:
        logger.error(f"Failed to build memories for user {user_id}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(
            status_code=500, detail=f"Failed to build memories: {str(e)}"
        )



