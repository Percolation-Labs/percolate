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
        metadata: Optional[Dict[str, Any]] = None,
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
            if "@" in user_id:
                user_uuid = make_uuid(user_id)
            else:
                user_uuid = user_id

            # Create memory instance
            memory = UserMemory(
                content=content,
                name=name,
                category=category or "user_memory",
                metadata=metadata or {},
                ordinal=0,
            )

            # Set userid after creation to avoid validation issues
            memory.userid = user_uuid

            # Save to repository
            p8.repository(UserMemory).update_records([memory])

            logger.info(f"Created memory {memory.name} for user {user_id}")
            return memory

        except Exception as e:
            logger.error(
                f"Error creating memory for user {user_id}: {str(e)}", exc_info=True
            )
            raise HTTPException(
                status_code=500, detail=f"Failed to create memory: {str(e)}"
            )

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
            if "@" in user_id:
                user_uuid = make_uuid(user_id)
            else:
                user_uuid = user_id

            memories = p8.repository(UserMemory).select(name=name, userid=user_id)

            if not memories:
                raise HTTPException(
                    status_code=404, detail=f"Memory '{name}' not found for user"
                )

            return memories[0]

        except HTTPException:
            raise
        except Exception as e:
            logger.error(
                f"Error retrieving memory {name} for user {user_id}: {str(e)}",
                exc_info=True,
            )
            raise HTTPException(
                status_code=500, detail=f"Failed to retrieve memory: {str(e)}"
            )

    async def list_recent(
        self, user_id: str, limit: int = 50, offset: int = 0
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
            if "@" in user_id:
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
                sql, data=(str(user_uuid), limit, offset)
            )

            return memories

        except Exception as e:
            logger.error(
                f"Error listing memories for user {user_id}: {str(e)}", exc_info=True
            )
            raise HTTPException(
                status_code=500, detail=f"Failed to list memories: {str(e)}"
            )

    async def search(
        self,
        user_id: str,
        query: Optional[str] = None,
        category: Optional[str] = None,
        limit: int = 50,
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
            if "@" in user_id:
                user_uuid = make_uuid(user_id)
            else:
                user_uuid = user_id

            # Use repository select to filter by user and category, then search
            repo = p8.repository(UserMemory)
            
            if query:
                # If we have a search query, use the search method (which returns raw results)
                logger.info(f"Calling repo.search with query: '{query}' for user: {user_uuid}")
                search_results = repo.search(query)
                logger.info(f"Search results type: {type(search_results)}, length: {len(search_results) if isinstance(search_results, list) else 'N/A'}")
                
                # Parse search results to extract UserMemory objects
                memories = []
                if search_results and isinstance(search_results, list):
                    for result in search_results:
                        if isinstance(result, dict):
                            # Check for vector results first
                            if 'vector_result' in result:
                                vector_results = result.get('vector_result', [])
                                for item in vector_results:
                                    if isinstance(item, dict) and str(item.get('userid')) == str(user_uuid):
                                        if not category or item.get('category') == category:
                                            # Convert dict to UserMemory object
                                            try:
                                                memory_obj = UserMemory(**item)
                                                memories.append(memory_obj)
                                            except Exception as e:
                                                logger.warning(f"Failed to parse memory object: {e}")
                                                continue
                            
                            # Check for relational results
                            elif 'relational_result' in result:
                                relational_results = result.get('relational_result', [])
                                for item in relational_results:
                                    if isinstance(item, dict) and str(item.get('userid')) == str(user_uuid):
                                        if not category or item.get('category') == category:
                                            # Convert dict to UserMemory object
                                            try:
                                                memory_obj = UserMemory(**item)
                                                memories.append(memory_obj)
                                            except Exception as e:
                                                logger.warning(f"Failed to parse memory object: {e}")
                                                continue
                
                # Limit results
                memories = memories[:limit]
            else:
                # If no query, just select by user and category
                filter_params = {"userid": str(user_uuid)}
                if category:
                    filter_params["category"] = category
                
                # Use select_with_predicates to support limit parameter
                memory_dicts = repo.select_with_predicates(
                    filter=filter_params, 
                    limit=limit,
                    order_by="updated_at DESC"
                )
                
                # Convert dictionaries to UserMemory objects
                memories = []
                for memory_dict in memory_dicts:
                    try:
                        memory_obj = UserMemory(**memory_dict)
                        memories.append(memory_obj)
                    except Exception as e:
                        logger.warning(f"Failed to parse memory object: {e}")
                        continue

            return memories

        except Exception as e:
            logger.error(
                f"Error searching memories for user {user_id}: {str(e)}", exc_info=True
            )
            raise HTTPException(
                status_code=500, detail=f"Failed to search memories: {str(e)}"
            )

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
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }



# Create singleton instance
user_memory_controller = UserMemoryController()
