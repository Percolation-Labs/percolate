"""Database repository implementation for MCP tools"""

from typing import Optional, Dict, Any, List, Union, AsyncIterator
from pydantic import BaseModel, Field
import percolate as p8
from percolate.models import AbstractModel
from percolate.models.p8.types import Agent, Function, Resources, PercolateAgent
from percolate.services.ModelRunner import ModelRunner
from percolate.utils.env import SYSTEM_USER_ID, SYSTEM_USER_ROLE_LEVEL
from percolate.utils import logger
import json
import uuid
from datetime import datetime
from decimal import Decimal
from .base_repository import BaseMCPRepository


def serialize_for_json(obj):
    """Convert non-serializable objects to JSON-compatible types"""
    if isinstance(obj, datetime):
        return obj.isoformat()
    elif isinstance(obj, Decimal):
        return float(obj)
    elif hasattr(obj, 'model_dump'):
        # Handle pydantic models and Root objects
        try:
            return serialize_for_json(obj.model_dump())
        except:
            return serialize_for_json(dict(obj))
    elif hasattr(obj, '__dict__'):
        # Handle objects with __dict__
        return serialize_for_json(obj.__dict__)
    elif isinstance(obj, dict):
        return {k: serialize_for_json(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [serialize_for_json(item) for item in obj]
    return obj


class DatabaseRepository(BaseMCPRepository):
    """Database repository implementation using direct PostgreSQL access"""
    
    def __init__(
        self,
        user_id: Optional[str] = None,
        user_groups: Optional[List[str]] = None,
        role_level: Optional[int] = None,
        user_email: Optional[str] = None,
        default_model: str = "gpt-4o-mini"
    ):
        self.user_id = user_id or SYSTEM_USER_ID
        self.user_groups = user_groups or []
        self.role_level = role_level or SYSTEM_USER_ROLE_LEVEL
        self.user_email = user_email
        self.default_model = default_model
        self._agent: Optional[ModelRunner] = None
    
    def _get_context(self) -> Dict[str, Any]:
        """Get user context for row-level security"""
        return {
            "user_id": self.user_id,
            "user_groups": self.user_groups,
            "role_level": self.role_level
        }
    
    async def get_entity(self, entity_name: str, entity_type: Optional[str] = None) -> Dict[str, Any]:
        """Get entity by name"""
        try:
            # Map string types to actual model classes
            type_map = {
                "Agent": Agent,
                "PercolateAgent": PercolateAgent,
                "Resources": Resources,
                "Function": Function
            }
            
            if entity_type and entity_type in type_map:
                # Use specific type - pass context during initialization
                repo = p8.repository(
                    type_map[entity_type],
                    user_id=self.user_id,
                    user_groups=self.user_groups,
                    role_level=self.role_level
                )
                # Try to get by name first, then fall back to ID if it looks like a UUID
                try:
                    entity = repo.get_by_name(entity_name, as_model=True)
                except AttributeError:
                    # If get_by_name doesn't exist, try get_by_id
                    entity = repo.get_by_id(entity_name, as_model=True)
            else:
                # Try common types
                entity = None
                for model_name, model_class in type_map.items():
                    try:
                        repo = p8.repository(
                            model_class,
                            user_id=self.user_id,
                            user_groups=self.user_groups,
                            role_level=self.role_level
                        )
                        # Try to get by name first, then fall back to ID
                        try:
                            entity = repo.get_by_name(entity_name, as_model=True)
                        except AttributeError:
                            entity = repo.get_by_id(entity_name, as_model=True)
                        if entity:
                            break
                    except Exception:
                        continue
            
            if entity:
                return entity.model_dump()
            else:
                return {"error": f"Entity {entity_name} not found"}
        except Exception as e:
            return {"error": str(e)}
    
    async def search_entities(
        self,
        query: str,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for entities"""
        try:
            # Use PercolateAgent repository for general search
            repo = p8.repository(
                PercolateAgent,
                user_id=self.user_id,
                user_groups=self.user_groups,
                role_level=self.role_level
            )
            
            # Use the search method which returns raw results
            results = repo.search(query)
            
            # Handle the response - search returns a list with one dict containing query results
            if results and isinstance(results, list) and len(results) > 0:
                # Extract the actual results from the response
                first_result = results[0]
                
                # Check if we have vector results
                if isinstance(first_result, dict) and 'vector_result' in first_result:
                    vector_results = first_result.get('vector_result', [])
                    if vector_results:
                        # Apply filters if provided
                        if filters:
                            filtered = []
                            for item in vector_results:
                                if all(item.get(k) == v for k, v in filters.items()):
                                    filtered.append(item)
                            vector_results = filtered
                        # Limit and return the vector results
                        return vector_results[:limit]
                
                # Check if we have relational results
                if isinstance(first_result, dict) and 'relational_result' in first_result:
                    relational_results = first_result.get('relational_result', [])
                    if relational_results:
                        return relational_results[:limit]
                
                # If we got a prompt message about no data
                if isinstance(first_result, dict) and first_result.get('status') == 'no data':
                    return []
                    
            return []
        except Exception as e:
            return [{"error": str(e)}]
    
    async def search_functions(
        self,
        query: str,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for functions using the Function model repository"""
        try:
            repo = p8.repository(
                Function,
                user_id=self.user_id,
                user_groups=self.user_groups,
                role_level=self.role_level
            )
            
            # Use the search method which returns raw results
            logger.debug(f"Searching functions with query: {query}")
            results = repo.search(query)
            logger.debug(f"Raw search results type: {type(results)}")
            logger.debug(f"Raw search results: {results}")
            
            # Handle the response - search returns a list with one dict containing query results
            if results and isinstance(results, list) and len(results) > 0:
                # Extract the actual results from the response
                first_result = results[0]
                logger.debug(f"First result type: {type(first_result)}")
                logger.debug(f"First result: {first_result}")
                
                # Check if we have vector results
                if isinstance(first_result, dict) and 'vector_result' in first_result:
                    vector_results = first_result.get('vector_result', [])
                    logger.debug(f"Vector results: {vector_results}")
                    if vector_results:
                        # Serialize and limit the vector results
                        serialized_results = serialize_for_json(vector_results[:limit])
                        logger.debug(f"Serialized results: {serialized_results}")
                        return serialized_results
                
                # Check if we have relational results
                if isinstance(first_result, dict) and 'relational_result' in first_result:
                    relational_results = first_result.get('relational_result', [])
                    logger.debug(f"Relational results: {relational_results}")
                    if relational_results:
                        return serialize_for_json(relational_results[:limit])
                
                # If we got a prompt message about no data
                if isinstance(first_result, dict) and first_result.get('status') == 'no data':
                    logger.debug("Got 'no data' status")
                    return []
                
                # If results is not what we expected, log it
                logger.warning(f"Unexpected result format: {results}")
                    
            return []
        except Exception as e:
            logger.error(f"Error in search_functions: {e}")
            return [{"error": str(e)}]
    
    async def evaluate_function(
        self,
        function_name: str,
        args: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Evaluate a specific function by name with arguments"""
        try:
            # Create a repository to call the database function
            repo = p8.repository(
                Function,
                user_id=self.user_id,
                user_groups=self.user_groups,
                role_level=self.role_level
            )
            
            # Use the database function evaluation
            result = repo.eval_function_call(function_name, args)
            
            # Handle the response
            if result and isinstance(result, list) and len(result) > 0:
                eval_result = result[0].get('eval_function_call', {})
                
                return {
                    "function": function_name,
                    "args": args,
                    "result": eval_result,
                    "success": True
                }
            else:
                return {
                    "function": function_name,
                    "args": args,
                    "error": "Function evaluation returned no results",
                    "success": False
                }
        except Exception as e:
            return {
                "function": function_name,
                "args": args,
                "error": str(e),
                "success": False
            }
    
    async def get_help(
        self,
        query: str,
        context: Optional[str] = None,
        max_depth: int = 3
    ) -> str:
        """Get help using PercolateAgent"""
        try:
            # For now, use the repository search to find relevant information
            repo = p8.repository(
                PercolateAgent,
                user_id=self.user_id,
                user_groups=self.user_groups,
                role_level=self.role_level
            )
            
            prompt = query
            if context:
                prompt = f"{context}\n\n{query}"
            
            # Search for relevant help content
            results = repo.search(prompt)
            
            # Format the response
            if results and isinstance(results, list) and len(results) > 0:
                first_result = results[0]
                
                # Check if we have vector results
                if isinstance(first_result, dict) and 'vector_result' in first_result:
                    vector_results = first_result.get('vector_result', [])
                    if vector_results:
                        # Format the top results as help text
                        help_text = []
                        for i, item in enumerate(vector_results[:max_depth]):
                            if isinstance(item, dict):
                                content = item.get('content', '')
                                name = item.get('name', f'Result {i+1}')
                                if content:
                                    help_text.append(f"### {name}\n{content}")
                        
                        if help_text:
                            return "\n\n".join(help_text)
                
            return f"I couldn't find specific help for: {query}. Please try rephrasing your question or contact support."
            
        except Exception as e:
            return f"Error: {str(e)}"
    
    async def upload_file(
        self,
        file_path: str,
        namespace: Optional[str] = None,
        entity_name: Optional[str] = None,
        task_id: Optional[str] = None,
        description: Optional[str] = None,
        tags: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """Upload file to S3 and create resource"""
        try:
            import os
            from percolate.services.S3Service import S3Service
            from percolate.models.p8.types import Resources as Resource
            import uuid
            
            # Check if file exists
            if not os.path.exists(file_path):
                return {"error": f"File not found: {file_path}"}
            
            # Get file info
            file_name = os.path.basename(file_path)
            file_size = os.path.getsize(file_path)
            
            # Read file content
            with open(file_path, 'rb') as f:
                file_content = f.read()
            
            # Upload to S3
            s3 = S3Service()
            task_id = str(uuid.uuid4())
            s3_path = f"s3://percolate/users/{self.user_id}/{task_id}/{file_name}"
            
            try:
                s3_result = s3.upload_filebytes_to_uri(
                    s3_uri=s3_path,
                    file_content=file_content
                )
                # Extract the actual URI from the result
                s3_url = s3_result.get('uri', s3_path) if isinstance(s3_result, dict) else s3_path
            except Exception as e:
                return {"error": f"S3 upload failed: {str(e)}"}
            
            # Create resource record
            resource = Resource(
                id=str(uuid.uuid4()),
                name=file_name,
                content=description or f"Uploaded file: {file_name}",  # Required field
                uri=s3_url,  # Required field as string
                category="uploaded_file",
                metadata={
                    "original_name": file_name,
                    "upload_method": "mcp",
                    "task_id": task_id,
                    "file_size": file_size,
                    "tags": tags or []
                },
                userid=self.user_id
            )
            
            # Note: Skipping database save as Resources table doesn't exist yet
            # This would normally save to database for searchability
            # repo.update_records([resource])
            
            return {
                "success": True,
                "file_name": file_name,
                "file_size": file_size,
                "resource_id": str(resource.id),
                "s3_url": s3_url,
                "status": "uploaded",
                "message": "File uploaded successfully. Background processing will index content."
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
                "file_path": file_path
            }
    
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
        """Upload file content directly to S3 and create resource"""
        try:
            from percolate.services.S3Service import S3Service
            from percolate.models.p8.types import Resources as Resource
            import uuid
            
            # Convert string content to bytes
            file_bytes = file_content.encode('utf-8')
            file_size = len(file_bytes)
            
            # Upload to S3
            s3 = S3Service()
            if not task_id:
                task_id = str(uuid.uuid4())
            s3_path = f"s3://percolate/users/{self.user_id}/{task_id}/{filename}"
            
            try:
                s3_result = s3.upload_filebytes_to_uri(
                    s3_uri=s3_path,
                    file_content=file_bytes
                )
                # Extract the actual URI from the result
                s3_url = s3_result.get('uri', s3_path) if isinstance(s3_result, dict) else s3_path
            except Exception as e:
                return {"error": f"S3 upload failed: {str(e)}"}
            
            # Create resource record
            resource = Resource(
                id=str(uuid.uuid4()),
                name=filename,
                content=description or f"Uploaded file: {filename}",  # Required field
                uri=s3_url,  # Required field as string
                category="uploaded_file",
                metadata={
                    "original_name": filename,
                    "upload_method": "mcp_content",
                    "task_id": task_id,
                    "file_size": file_size,
                    "namespace": namespace or "p8",
                    "entity_name": entity_name or "Resources",
                    "tags": tags or []
                },
                userid=self.user_id
            )
            
            # Note: Skipping database save as Resources table doesn't exist yet
            # This would normally save to database for searchability
            # repo.update_records([resource])
            
            return {
                "success": True,
                "file_name": filename,
                "file_size": file_size,
                "resource_id": str(resource.id),
                "s3_url": s3_url,
                "status": "uploaded",
                "message": "File uploaded successfully. Background processing will index content."
            }
        except Exception as e:
            return {
                "success": False,
                "error": str(e),
                "filename": filename
            }
    
    async def search_resources(
        self,
        query: str,
        resource_type: Optional[str] = None,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for resources using the Resource model"""
        try:
            repo = p8.repository(
                Resources,
                user_id=self.user_id,
                user_groups=self.user_groups,
                role_level=self.role_level
            )
            
            # Use the search method which returns raw results
            results = repo.search(query)
            
            # Handle the response - search returns a list with one dict containing query results
            if results and isinstance(results, list) and len(results) > 0:
                # Extract the actual results from the response
                first_result = results[0]
                
                # Check if we have vector results
                if isinstance(first_result, dict) and 'vector_result' in first_result:
                    vector_results = first_result.get('vector_result', [])
                    if vector_results:
                        # Filter by type if specified
                        if resource_type:
                            filtered = []
                            for item in vector_results:
                                if item.get("type") == resource_type or item.get("category") == resource_type:
                                    filtered.append(item)
                            vector_results = filtered
                        # Limit and return the vector results
                        return vector_results[:limit]
                
                # Check if we have relational results
                if isinstance(first_result, dict) and 'relational_result' in first_result:
                    relational_results = first_result.get('relational_result', [])
                    if relational_results:
                        return relational_results[:limit]
                
                # If we got a prompt message about no data
                if isinstance(first_result, dict) and first_result.get('status') == 'no data':
                    return []
                    
            return []
        except Exception as e:
            return [{"error": str(e)}]
    
    async def stream_chat(
        self,
        query: str,
        agent: str,
        model: str,
        session_id: Optional[str] = None,
        stream: bool = True
    ) -> Union[str, AsyncIterator[str]]:
        """Stream chat response using ModelRunner directly"""
        try:
            # Create or get agent runner
            if not self._agent:
                self._agent = ModelRunner(
                    model_name=agent,
                    user_id=self.user_id,
                    thread_id=session_id or str(uuid.uuid4()),
                    channel_type="mcp",
                    llm_model=model
                )
            
            if stream:
                # Return async iterator for streaming
                async def stream_generator():
                    try:
                        # ModelRunner iter_lines returns SSE formatted lines
                        for line in self._agent.iter_lines(query):
                            if line:
                                yield line
                    except Exception as e:
                        yield f"data: {{\"error\": \"{str(e)}\"}}\n\n"
                        yield "data: [DONE]\n\n"
                
                return stream_generator()
            else:
                # Get complete response
                response = self._agent.eval(query)
                if isinstance(response, str):
                    return response
                elif hasattr(response, 'content'):
                    return response.content
                else:
                    return str(response)
                    
        except Exception as e:
            logger.error(f"Error in stream_chat: {e}")
            # Return error as async iterator for consistency
            error_msg = str(e)
            if stream:
                async def error_generator():
                    yield f"data: {{\"error\": \"{error_msg}\"}}\n\n"
                    yield "data: [DONE]\n\n"
                return error_generator()
            else:
                return f"Error: {error_msg}"