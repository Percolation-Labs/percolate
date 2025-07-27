"""API proxy repository implementation for MCP tools"""

from typing import Optional, Dict, Any, List, Union, AsyncIterator
import httpx
from percolate.utils import logger
from .base_repository import BaseMCPRepository
import os
import json
from pathlib import Path


class APIProxyRepository(BaseMCPRepository):
    """API proxy repository implementation using HTTP/REST calls"""
    
    def __init__(
        self,
        api_endpoint: str,
        api_key: Optional[str] = None,
        oauth_token: Optional[str] = None,
        user_email: Optional[str] = None,
        timeout: float = 30.0,
        additional_headers: Optional[Dict[str, str]] = None
    ):
        """Initialize API proxy repository.
        
        Args:
            api_endpoint: Base URL of the Percolate API
            api_key: Bearer token for authentication
            oauth_token: OAuth access token (alternative to api_key)
            user_email: User email for identification
            timeout: Request timeout in seconds
        """
        self.api_endpoint = api_endpoint.rstrip('/')
        self.api_key = api_key
        self.oauth_token = oauth_token
        self.user_email = user_email
        self.timeout = timeout
        
        # Setup headers - don't set Content-Type here as it will be set automatically
        # for different request types (json vs multipart)
        self.headers = {
            "Accept": "application/json"
        }
        
        # Add authentication
        if oauth_token:
            self.headers["Authorization"] = f"Bearer {oauth_token}"
        elif api_key:
            self.headers["Authorization"] = f"Bearer {api_key}"
            if user_email:
                self.headers["X-User-Email"] = user_email
        
        # Add any additional headers (X-headers from MCP context)
        if additional_headers:
            self.headers.update(additional_headers)
        
        # Create async client
        self.client = httpx.AsyncClient(
            base_url=self.api_endpoint,
            headers=self.headers,
            timeout=self.timeout
        )
    
    async def _handle_response(self, response: httpx.Response) -> Any:
        """Handle API response and errors"""
        try:
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as e:
            logger.error(f"API error: {e.response.status_code} - {e.response.text}")
            return {"error": f"API error: {e.response.status_code}"}
        except Exception as e:
            logger.error(f"Request failed: {str(e)}")
            return {"error": str(e)}
    
    async def get_entity(self, entity_name: str, entity_type: Optional[str] = None) -> Dict[str, Any]:
        """Get entity by name via API"""
        try:
            # Try the entities endpoint first
            response = await self.client.get(f"/entities/{entity_name}")
            data = await self._handle_response(response)
            
            if "error" not in data:
                return data
            
            # If not found and we have a type, try type-specific endpoint
            if entity_type:
                type_endpoints = {
                    "Agent": "/entities",
                    "Function": "/tools",
                    "Resources": "/admin/content/files"
                }
                
                if entity_type in type_endpoints:
                    endpoint = type_endpoints[entity_type]
                    response = await self.client.get(f"{endpoint}/{entity_name}")
                    return await self._handle_response(response)
            
            return data
        except Exception as e:
            logger.error(f"Error getting entity: {e}")
            return {"error": str(e)}
    
    async def search_entities(
        self,
        query: str,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for entities via API"""
        try:
            # Use the entities search endpoint
            payload = {
                "query": query,
                "limit": limit
            }
            if filters:
                payload["filters"] = filters
            
            response = await self.client.post("/entities/search", json=payload)
            data = await self._handle_response(response)
            
            if isinstance(data, list):
                return data
            elif isinstance(data, dict) and "results" in data:
                return data["results"]
            elif isinstance(data, dict) and "error" not in data:
                return [data]
            else:
                return []
        except Exception as e:
            logger.error(f"Error searching entities: {e}")
            return [{"error": str(e)}]
    
    async def search_functions(
        self,
        query: str,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for functions via API"""
        try:
            payload = {
                "query": query,
                "limit": limit
            }
            
            response = await self.client.post("/tools/search", json=payload)
            data = await self._handle_response(response)
            
            if isinstance(data, list):
                return data
            elif isinstance(data, dict) and "results" in data:
                return data["results"]
            elif isinstance(data, dict) and "functions" in data:
                return data["functions"]
            else:
                return []
        except Exception as e:
            logger.error(f"Error searching functions: {e}")
            return [{"error": str(e)}]
    
    async def evaluate_function(
        self,
        function_name: str,
        args: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Evaluate a function via API"""
        try:
            payload = {
                "name": function_name,
                "arguments": args  # API expects 'arguments' not 'args'
            }
            
            response = await self.client.post("/tools/eval", json=payload)
            data = await self._handle_response(response)
            
            # Standardize response format
            if isinstance(data, list):
                # API returns a list directly
                return {
                    "function": function_name,
                    "args": args,
                    "result": data,
                    "success": True
                }
            elif isinstance(data, dict) and "error" not in data:
                if "result" not in data:
                    # Wrap raw result
                    return {
                        "function": function_name,
                        "args": args,
                        "result": data,
                        "success": True
                    }
                return data
            else:
                error_msg = data.get("error", "Unknown error") if isinstance(data, dict) else str(data)
                return {
                    "function": function_name,
                    "args": args,
                    "error": error_msg,
                    "success": False
                }
        except Exception as e:
            logger.error(f"Error evaluating function: {e}")
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
        """Get help via API - using entity search as fallback"""
        try:
            # Try to search for relevant help content
            search_query = f"{context} {query}" if context else query
            results = await self.search_entities(search_query, limit=max_depth)
            
            if results and not any("error" in r for r in results):
                # Format results as help text
                help_text = []
                for i, result in enumerate(results[:max_depth]):
                    name = result.get("name", f"Result {i+1}")
                    content = result.get("description", result.get("content", ""))
                    if content:
                        help_text.append(f"### {name}\n{content}")
                
                if help_text:
                    return "\n\n".join(help_text)
            
            return f"I couldn't find specific help for: {query}. Please try rephrasing your question or contact support."
        except Exception as e:
            logger.error(f"Error getting help: {e}")
            return f"Error retrieving help: {str(e)}"
    
    async def upload_file(
        self,
        file_path: str,
        namespace: Optional[str] = None,
        entity_name: Optional[str] = None,
        task_id: Optional[str] = None,
        description: Optional[str] = None,
        tags: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """Upload file via API"""
        try:
            # Check if file exists
            if not os.path.exists(file_path):
                return {"error": f"File not found: {file_path}"}
            
            # Detect content type from file extension
            import mimetypes
            content_type, _ = mimetypes.guess_type(file_path)
            if not content_type:
                content_type = "application/octet-stream"  # Default for unknown types
                
            # Prepare multipart upload
            with open(file_path, 'rb') as f:
                files = {"file": (Path(file_path).name, f, content_type)}
                data = {
                    "add_resource": "true",
                    "namespace": namespace or "p8",
                    "entity_name": entity_name or "Resources"
                }
                
                # Add optional parameters
                if task_id:
                    data["task_id"] = task_id
                elif description:
                    data["task_id"] = description  # Use description as task_id fallback
                    
                # Use admin upload endpoint
                response = await self.client.post(
                    "/admin/content/upload",
                    files=files,
                    data=data
                )
                
                result = await self._handle_response(response)
                
                if "error" not in result:
                    return {
                        "success": True,
                        "file_name": Path(file_path).name,
                        "file_size": os.path.getsize(file_path),
                        **result
                    }
                else:
                    return {
                        "success": False,
                        "error": result.get("error", "Upload failed"),
                        "file_path": file_path
                    }
        except Exception as e:
            logger.error(f"Error uploading file: {e}")
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
        """Upload file content directly via API"""
        try:
            import io
            import mimetypes
            
            # Detect content type from filename
            content_type, _ = mimetypes.guess_type(filename)
            if not content_type:
                content_type = "text/plain" if filename.endswith(('.txt', '.md')) else "application/octet-stream"
            
            # Convert string content to bytes
            file_bytes = file_content.encode('utf-8')
            file_like = io.BytesIO(file_bytes)
            
            # Prepare multipart upload
            files = {"file": (filename, file_like, content_type)}
            data = {
                "add_resource": "true",
                "namespace": namespace or "p8",
                "entity_name": entity_name or "Resources"
            }
            
            # Add optional parameters
            if task_id:
                data["task_id"] = task_id
            elif description:
                data["task_id"] = description  # Use description as task_id fallback
                
            # Use admin upload endpoint
            response = await self.client.post(
                "/admin/content/upload",
                files=files,
                data=data
            )
            
            result = await self._handle_response(response)
            
            if "error" not in result:
                return {
                    "success": True,
                    "file_name": filename,
                    "file_size": len(file_bytes),
                    **result
                }
            else:
                return {
                    "success": False,
                    "error": result.get("error", "Upload failed"),
                    "filename": filename
                }
        except Exception as e:
            logger.error(f"Error uploading file content: {e}")
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
        """Search for resources via API"""
        try:
            # Use TUS search endpoint for files
            params = {
                "search": query,
                "limit": limit
            }
            
            if resource_type:
                params["type"] = resource_type
            
            response = await self.client.get("/tus/", params=params)
            data = await self._handle_response(response)
            
            if isinstance(data, list):
                return data
            elif isinstance(data, dict) and "uploads" in data:
                return data["uploads"]
            elif isinstance(data, dict) and "files" in data:
                return data["files"]
            else:
                # Fallback to entity search
                return await self.search_entities(query, {"type": "resource"}, limit)
        except Exception as e:
            logger.error(f"Error searching resources: {e}")
            return [{"error": str(e)}]
    
    async def ping(self) -> Dict[str, Any]:
        """Test authentication with ping endpoint"""
        try:
            response = await self.client.get("/auth/ping")
            return await self._handle_response(response)
        except Exception as e:
            logger.error(f"Ping failed: {str(e)}")
            return {"error": str(e)}
    
    async def stream_chat(
        self,
        query: str,
        agent: str,
        model: str,
        session_id: Optional[str] = None,
        stream: bool = True
    ) -> Union[str, AsyncIterator[str]]:
        """Stream chat response from agent via API"""
        try:
            import uuid
            
            # Build the chat completions request
            payload = {
                "model": model,
                "messages": [
                    {"role": "user", "content": query}
                ],
                "stream": stream
            }
            
            # Add session ID if provided
            params = {}
            if session_id:
                params["session_id"] = session_id
            else:
                params["session_id"] = str(uuid.uuid4())
            
            # Use the agent-specific endpoint
            endpoint = f"/agent/{agent}/completions"
            
            if stream:
                # Return async iterator for streaming
                async def stream_generator():
                    async with self.client.stream(
                        "POST",
                        endpoint,
                        json=payload,
                        params=params,
                        timeout=60.0
                    ) as response:
                        response.raise_for_status()
                        async for line in response.aiter_lines():
                            if line:
                                yield line
                
                return stream_generator()
            else:
                # Return complete response for non-streaming
                response = await self.client.post(
                    endpoint,
                    json=payload,
                    params=params
                )
                data = await self._handle_response(response)
                
                # Extract content from response
                if isinstance(data, dict) and "choices" in data:
                    content = data["choices"][0].get("message", {}).get("content", "")
                    return content
                else:
                    return str(data)
                    
        except Exception as e:
            logger.error(f"Error in stream_chat: {e}")
            # Return error as async iterator for consistency
            async def error_generator():
                yield f"data: {{\"error\": \"{str(e)}\"}}\n\n"
                yield "data: [DONE]\n\n"
            return error_generator() if stream else f"Error: {str(e)}"
    
    async def close(self):
        """Close the HTTP client"""
        await self.client.aclose()