"""Abstract base class for MCP repository pattern"""

from abc import ABC, abstractmethod
from typing import Optional, Dict, Any, List, Union, AsyncIterator


class BaseMCPRepository(ABC):
    """Abstract base class defining the interface for MCP data operations.
    
    This allows for multiple implementations:
    - DatabaseRepository: Direct PostgreSQL access
    - APIProxyRepository: HTTP/REST API proxy
    """
    
    @abstractmethod
    async def get_entity(self, entity_name: str, entity_type: Optional[str] = None, allow_fuzzy_match: bool = True, similarity_threshold: float = 0.3) -> Dict[str, Any]:
        """Get entity by name.
        
        Args:
            entity_name: Name of the entity
            entity_type: Optional type hint (Agent, PercolateAgent, Resources, Function)
            allow_fuzzy_match: If True, uses fuzzy matching for similar names
            similarity_threshold: Threshold for fuzzy matching (0.0-1.0, lower = more permissive)
            
        Returns:
            Entity data as dictionary or error dict
        """
        pass
    
    @abstractmethod
    async def search_entities(
        self,
        query: str,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for entities using natural language.
        
        Args:
            query: Natural language search query
            filters: Optional filters to apply
            limit: Maximum number of results
            
        Returns:
            List of matching entities
        """
        pass
    
    @abstractmethod
    async def list_entities(
        self,
        entity_type: str,
        limit: int = 100,
        offset: int = 0
    ) -> List[Dict[str, Any]]:
        """List all entities of a specific type.
        
        Args:
            entity_type: Type of entities to list (e.g., 'p8.Function')
            limit: Maximum number of results
            offset: Offset for pagination
            
        Returns:
            List of entities with their basic information
        """
        pass
    
    @abstractmethod
    async def search_functions(
        self,
        query: str,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for functions using semantic search.
        
        Args:
            query: Natural language search query
            limit: Maximum number of results
            
        Returns:
            List of matching functions
        """
        pass
    
    @abstractmethod
    async def evaluate_function(
        self,
        function_name: str,
        args: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Evaluate a function with given arguments.
        
        Args:
            function_name: Name of the function to execute
            args: Arguments to pass to the function
            
        Returns:
            Execution result with success status
        """
        pass
    
    @abstractmethod
    async def get_help(
        self,
        query: str,
        context: Optional[str] = None,
        max_depth: int = 3
    ) -> str:
        """Get help using PercolateAgent.
        
        Args:
            query: Help query
            context: Optional context for the query
            max_depth: Maximum depth of results to return
            
        Returns:
            Help text response
        """
        pass
    
    @abstractmethod
    async def upload_file(
        self,
        file_path: str,
        namespace: Optional[str] = None,
        entity_name: Optional[str] = None,
        task_id: Optional[str] = None,
        description: Optional[str] = None,
        tags: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """Upload file from filesystem to storage.
        
        Args:
            file_path: Local path to file
            namespace: Target namespace (uses default if not provided)
            entity_name: Target entity (uses default if not provided)
            task_id: Optional task ID for tracking
            description: Optional file description
            tags: Optional tags for categorization
            
        Returns:
            Upload result with file metadata
        """
        pass
    
    @abstractmethod
    async def upload_file_content(
        self,
        file_content: str,
        filename: str,
        namespace: Optional[str] = None,
        entity_name: Optional[str] = None,
        task_id: Optional[str] = None,
        description: Optional[str] = None,
        tags: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """Upload file content directly to storage.
        
        Args:
            file_content: Content to upload
            filename: Name for the file
            namespace: Target namespace (uses default if not provided)
            entity_name: Target entity (uses default if not provided)
            task_id: Optional task ID for tracking
            description: Optional file description
            tags: Optional tags for categorization
            
        Returns:
            Upload result with file metadata
        """
        pass
    
    @abstractmethod
    async def search_resources(
        self,
        query: str,
        resource_type: Optional[str] = None,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for resources.
        
        Args:
            query: Search query
            resource_type: Optional type filter
            limit: Maximum number of results
            
        Returns:
            List of matching resources
        """
        pass
    
    @abstractmethod
    async def stream_chat(
        self,
        query: str,
        agent: str,
        model: str,
        session_id: Optional[str] = None,
        stream: bool = True
    ) -> Union[str, AsyncIterator[str]]:
        """Stream chat response from agent.
        
        Args:
            query: User query/prompt
            agent: Agent name to use
            model: LLM model to use
            session_id: Optional session ID for conversation continuity
            stream: Whether to stream the response
            
        Returns:
            Either a complete response string or an async iterator of SSE lines
        """
        pass

    @abstractmethod
    async def add_memory(
        self,
        content: str,
        name: Optional[str] = None,
        category: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Add a new memory for the authenticated user"""
        pass

    @abstractmethod
    async def list_memories(
        self, limit: int = 50, offset: int = 0
    ) -> List[Dict[str, Any]]:
        """List memories for the authenticated user"""
        pass

    @abstractmethod
    async def get_memory(self, name: str) -> Dict[str, Any]:
        """Get a specific memory by name for the authenticated user"""
        pass

    @abstractmethod
    async def search_memories(
        self,
        query: Optional[str] = None,
        category: Optional[str] = None,
        limit: int = 50,
    ) -> List[Dict[str, Any]]:
        """Search memories by content or category for the authenticated user"""
        pass


    @abstractmethod
    async def build_memory(self) -> Dict[str, Any]:
        """Build memory summary for the authenticated user"""
        pass