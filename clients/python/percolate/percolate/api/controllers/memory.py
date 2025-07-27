"""
UserMemory controller for managing user-specific memories and facts
"""
import logging
from typing import List, Optional, Dict, Any
from datetime import datetime, timezone
import uuid

from fastapi import HTTPException
import percolate as p8
from percolate.models.p8.types import UserMemory
from percolate.utils import make_uuid

logger = logging.getLogger(__name__)


class UserMemoryController:
    """Controller for managing user memories"""
    
    async def add(
        self,
        user_id: str,
        content: str,
        name: Optional[str] = None,
        category: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None
    ) -> UserMemory:
        """Add a new memory for a user
        
        Args:
            user_id: The user's ID (email or UUID)
            content: The memory content
            name: Optional name for the memory (auto-generated if not provided)
            category: Optional category (defaults to 'user_memory')
            metadata: Optional additional metadata
            
        Returns:
            The created UserMemory instance
        """
        try:
            # Convert email to UUID if needed
            if '@' in user_id:
                user_uuid = make_uuid(user_id)
            else:
                user_uuid = user_id
            
            # Create memory instance
            memory = UserMemory(
                content=content,
                name=name,
                category=category or 'user_memory',
                metadata=metadata or {},
                ordinal=0
            )
            
            # Set userid after creation to avoid validation issues
            memory.userid = user_uuid
            
            # Save to repository
            p8.repository(UserMemory).update_records([memory])
            
            logger.info(f"Created memory {memory.name} for user {user_id}")
            return memory
            
        except Exception as e:
            logger.error(f"Error creating memory for user {user_id}: {str(e)}", exc_info=True)
            raise HTTPException(status_code=500, detail=f"Failed to create memory: {str(e)}")
    
    async def get(self, user_id: str, name: str) -> UserMemory:
        """Get a specific memory by name
        
        Args:
            user_id: The user's ID
            name: The memory name
            
        Returns:
            The UserMemory instance
            
        Raises:
            HTTPException: If memory not found
        """
        try:
            # Convert email to UUID if needed
            if '@' in user_id:
                user_uuid = make_uuid(user_id)
            else:
                user_uuid = user_id
                
            # Use repository to get by key
            memories = p8.repository(UserMemory).get_entities_by_keys(
                keys=[{"userid": str(user_uuid), "name": name}],
                as_model=True
            )
            
            if not memories:
                raise HTTPException(status_code=404, detail=f"Memory '{name}' not found for user")
            
            return memories[0]
            
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error retrieving memory {name} for user {user_id}: {str(e)}", exc_info=True)
            raise HTTPException(status_code=500, detail=f"Failed to retrieve memory: {str(e)}")
    
    async def list_recent(
        self, 
        user_id: str, 
        limit: int = 50,
        offset: int = 0
    ) -> List[UserMemory]:
        """List recent memories for a user ordered by updated_at desc
        
        Args:
            user_id: The user's ID
            limit: Maximum number of memories to return
            offset: Number of memories to skip
            
        Returns:
            List of UserMemory instances
        """
        try:
            # Convert email to UUID if needed
            if '@' in user_id:
                user_uuid = make_uuid(user_id)
            else:
                user_uuid = user_id
            
            # Use repository search with specific query
            sql = """
            SELECT name, category, content, summary, uri, metadata, 
                   resource_timestamp, userid, created_at, updated_at, id, ordinal
            FROM p8."UserMemory" 
            WHERE userid = %s 
            ORDER BY updated_at DESC 
            LIMIT %s OFFSET %s
            """
            
            # Execute query using repository's connection
            memories = p8.repository(UserMemory).execute(
                sql, 
                data=(str(user_uuid), limit, offset)
            )
            
            return memories
            
        except Exception as e:
            logger.error(f"Error listing memories for user {user_id}: {str(e)}", exc_info=True)
            raise HTTPException(status_code=500, detail=f"Failed to list memories: {str(e)}")
    
    async def search(
        self,
        user_id: str,
        query: Optional[str] = None,
        category: Optional[str] = None,
        limit: int = 50
    ) -> List[UserMemory]:
        """Search user memories using repository search
        
        Args:
            user_id: The user's ID
            query: Optional search query for content
            category: Optional category filter
            limit: Maximum number of results
            
        Returns:
            List of matching UserMemory instances
        """
        try:
            # Convert email to UUID if needed
            if '@' in user_id:
                user_uuid = make_uuid(user_id)
            else:
                user_uuid = user_id
                
            # Build search criteria
            search_params = {"userid": str(user_uuid)}
            
            if category:
                search_params["category"] = category
            
            # Use repository search
            memories = p8.repository(UserMemory).search(
                **search_params,
                query=query,
                limit=limit,
                as_model=True
            )
            
            return memories
            
        except Exception as e:
            logger.error(f"Error searching memories for user {user_id}: {str(e)}", exc_info=True)
            raise HTTPException(status_code=500, detail=f"Failed to search memories: {str(e)}")
    
    async def build(self, user_id: str) -> Dict[str, Any]:
        """Build memory summary for user (placeholder for future implementation)
        
        Args:
            user_id: The user's ID
            
        Returns:
            Dictionary with build status/results
        """
        # Placeholder implementation
        return {
            "status": "not_implemented",
            "message": "Memory building will be implemented in future",
            "user_id": user_id,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    
    async def delete(self, user_id: str, name: str) -> bool:
        """Delete a specific memory
        
        Args:
            user_id: The user's ID
            name: The memory name
            
        Returns:
            True if deleted successfully
        """
        try:
            # First check if memory exists
            memory = await self.get(user_id, name)
            
            # Delete using repository
            p8.repository(UserMemory).delete(id=memory.id)
            
            logger.info(f"Deleted memory {name} for user {user_id}")
            return True
            
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error deleting memory {name} for user {user_id}: {str(e)}", exc_info=True)
            raise HTTPException(status_code=500, detail=f"Failed to delete memory: {str(e)}")


# Create singleton instance
user_memory_controller = UserMemoryController()