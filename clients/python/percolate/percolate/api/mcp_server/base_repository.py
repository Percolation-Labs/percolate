"""Abstract base class for MCP repository pattern"""

from abc import ABC, abstractmethod
from typing import Optional, Dict, Any, List


class BaseMCPRepository(ABC):
    """Abstract base class defining the interface for MCP data operations.
    
    This allows for multiple implementations:
    - DatabaseRepository: Direct PostgreSQL access
    - APIProxyRepository: HTTP/REST API proxy
    """
    
    @abstractmethod
    async def get_entity(self, entity_name: str, entity_type: Optional[str] = None) -> Dict[str, Any]:
        """Get entity by name.
        
        Args:
            entity_name: Name of the entity
            entity_type: Optional type hint (Agent, PercolateAgent, Resources, Function)
            
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
        description: Optional[str] = None,
        tags: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """Upload file to storage.
        
        Args:
            file_path: Local path to file
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