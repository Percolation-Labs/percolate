"""API proxy repository implementation for MCP tools"""

from typing import Optional, Dict, Any, List, Union, AsyncIterator
import httpx
import logging
from .base_repository import BaseMCPRepository
from .exceptions import (
    APIError,
    EntityNotFoundError,
    FunctionExecutionError,
    FileOperationError,
)
import os
import json
from pathlib import Path
# Local environment variables (no dependency on percolate.utils.env)
P8_BASE_URI = os.getenv('P8_BASE_URI', 'http://localhost:5008')
POSTGRES_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'postgres')
DEFAULT_MODEL = os.getenv('DEFAULT_MODEL', 'gpt-3.5-turbo')

logger = logging.getLogger(__name__)


class APIProxyRepository(BaseMCPRepository):
    """API proxy repository implementation using HTTP/REST calls"""

    def __init__(
        self,
        api_endpoint: str = None,
        api_key: Optional[str] = None,
        oauth_token: Optional[str] = None,
        user_email: Optional[str] = None,
        timeout: float = 30.0,
        additional_headers: Optional[Dict[str, str]] = None,
    ):
        """Initialize API proxy repository.

        Args:
            api_endpoint: Base URL of the Percolate API
            api_key: Bearer token for authentication
            oauth_token: OAuth access token (alternative to api_key)
            user_email: User email for identification
            timeout: Request timeout in seconds
        """
        # Comprehensive logging of environment variables
        logger.info("=== APIProxyRepository Initialization ===")
        logger.info(f"Environment variables:")
        logger.info(f"  P8_BASE_URI: {os.getenv('P8_BASE_URI', 'NOT SET')}")
        logger.info(f"  P8_API_ENDPOINT: {os.getenv('P8_API_ENDPOINT', 'NOT SET')}")
        logger.info(f"  P8_TEST_BEARER_TOKEN: {'SET' if os.getenv('P8_TEST_BEARER_TOKEN') else 'NOT SET'}")
        logger.info(f"  P8_API_KEY: {'SET' if os.getenv('P8_API_KEY') else 'NOT SET'}")
        logger.info(f"  P8_BASE_URI from utils.env: {P8_BASE_URI}")
        logger.info(f"  POSTGRES_PASSWORD from utils.env: {'SET' if POSTGRES_PASSWORD else 'NOT SET'}")
        
        logger.info(f"Parameters passed:")
        logger.info(f"  api_endpoint: {api_endpoint}")
        logger.info(f"  api_key: {'SET' if api_key else 'NOT SET'}")
        logger.info(f"  oauth_token: {'SET' if oauth_token else 'NOT SET'}")
        
        # Use environment variable if no endpoint provided
        if not api_endpoint:
            # First try P8_API_ENDPOINT directly from env
            api_endpoint = os.getenv('P8_API_ENDPOINT')
            if api_endpoint:
                logger.info(f"Using P8_API_ENDPOINT from environment: {api_endpoint}")
            else:
                # Fall back to P8_BASE_URI from utils
                api_endpoint = P8_BASE_URI
                if api_endpoint:
                    logger.info(f"Using P8_BASE_URI from utils.env: {api_endpoint}")
                else:
                    # Final fallback
                    api_endpoint = "https://p8.resmagic.io"
                    logger.info(f"Using hardcoded default: {api_endpoint}")
        
        self.api_endpoint = api_endpoint.rstrip("/")
        logger.info(f"Final API endpoint: {self.api_endpoint}")
        
        self.api_key = api_key
        self.oauth_token = oauth_token
        self.user_email = user_email
        self.timeout = timeout

        # Setup headers - don't set Content-Type here as it will be set automatically
        # for different request types (json vs multipart)
        self.headers = {"Accept": "application/json"}

        # Add authentication - prioritize explicit tokens over environment defaults
        auth_source = None
        if oauth_token:
            self.headers["Authorization"] = f"Bearer {oauth_token}"
            auth_source = "oauth_token parameter"
        elif api_key:
            self.headers["Authorization"] = f"Bearer {api_key}"
            auth_source = "api_key parameter"
        else:
            # Try environment variables in order: P8_TEST_BEARER_TOKEN, P8_API_KEY, POSTGRES_PASSWORD
            env_token = os.getenv('P8_TEST_BEARER_TOKEN')
            if env_token:
                self.headers["Authorization"] = f"Bearer {env_token}"
                auth_source = "P8_TEST_BEARER_TOKEN environment variable"
            else:
                env_token = os.getenv('P8_API_KEY')
                if env_token:
                    self.headers["Authorization"] = f"Bearer {env_token}"
                    auth_source = "P8_API_KEY environment variable"
                else:
                    # Final fallback to POSTGRES_PASSWORD from utils.env
                    env_token = POSTGRES_PASSWORD
                    if env_token:
                        self.headers["Authorization"] = f"Bearer {env_token}"
                        auth_source = "POSTGRES_PASSWORD from utils.env"
        
        if auth_source:
            logger.info(f"Authentication configured from: {auth_source}")
            logger.info(f"Auth header set: Bearer {'*' * 10}...")  # Masked for security
        else:
            logger.warning("NO AUTHENTICATION TOKEN FOUND - API calls may fail")
        
        # Always add user email header if provided
        if user_email:
            self.headers["X-User-Email"] = user_email
            logger.info(f"User email header set: {user_email}")

        # Add any additional headers (X-headers from MCP context)
        if additional_headers:
            self.headers.update(additional_headers)
            logger.info(f"Additional headers added: {list(additional_headers.keys())}")

        logger.info("=== APIProxyRepository Initialization Complete ===")

        # Create async client
        self.client = httpx.AsyncClient(
            base_url=self.api_endpoint, headers=self.headers, timeout=self.timeout
        )

    async def _handle_response(self, response: httpx.Response) -> Any:
        """Handle API response and errors"""
        try:
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as e:
            logger.error(f"API error: {e.response.status_code} - {e.response.text}")
            raise APIError(
                f"API request failed with status {e.response.status_code}",
                status_code=e.response.status_code,
                endpoint=str(response.url),
            )
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON response: {str(e)}")
            raise APIError("Invalid JSON response from API", endpoint=str(response.url))
        except Exception as e:
            logger.error(f"Request failed: {str(e)}")
            raise APIError(f"API request failed: {str(e)}", endpoint=str(response.url))

    async def get_entity(
        self,
        entity_name: str,
        entity_type: Optional[str] = None,
        allow_fuzzy_match: bool = True,
        similarity_threshold: float = 0.3,
    ) -> Dict[str, Any]:
        """Get entity by name via API - uses the /entities/get endpoint"""
        # Use the new /entities/get endpoint
        logger.debug(
            f"Getting entity {entity_name} via /entities/get (fuzzy: {allow_fuzzy_match})"
        )
        payload = {
            "keys": [entity_name],
            "allow_fuzzy_match": allow_fuzzy_match,
            "similarity_threshold": similarity_threshold,
        }

        response = await self.client.post(
            f"{self.api_endpoint}/entities/get", json=payload
        )
        result = await self._handle_response(response)

        # Return the result directly - it should contain get_entities or get_fuzzy_entities
        if isinstance(result, dict):
            # Check if it's an error response
            if "error" in result:
                raise EntityNotFoundError(entity_name, entity_type)
            # Check if we have entities data
            if "get_entities" in result or "get_fuzzy_entities" in result:
                entities_key = (
                    "get_entities" if "get_entities" in result else "get_fuzzy_entities"
                )
                entities_data = result.get(entities_key, {})
                if isinstance(entities_data, dict) and "data" in entities_data:
                    entities = entities_data["data"]
                    if entities and len(entities) > 0:
                        return entities[0]
            return result

        # If we didn't find the entity, raise an error
        raise EntityNotFoundError(entity_name, entity_type)

    async def search_entities(
        self,
        query: str,
        entity_name: str = None,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = 10,
    ) -> List[Dict[str, Any]]:
        """Search for entities via API"""
        try:
            # Use the entities search endpoint
            payload = {"query": query, "limit": limit}
            if filters:
                payload["filters"] = filters
            if entity_name:
                payload["entity_name"] = entity_name

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
            logger.error(f"Error searching entities: {str(e)}")
            return []

    async def list_entities(
        self,
        entity_type: str,
        limit: int = 100,
        offset: int = 0
    ) -> List[Dict[str, Any]]:
        """List entities via API"""
        try:
            params = {"limit": limit, "offset": offset}
            
            # For p8.Function, use the /entities/list endpoint
            if entity_type == "p8.Function":
                response = await self.client.get(f"/entities/list/{entity_type}", params=params)
                data = await self._handle_response(response)
                
                if isinstance(data, list):
                    return data
                elif isinstance(data, dict) and "entities" in data:
                    return data["entities"]
                elif isinstance(data, dict) and "results" in data:
                    return data["results"]
                else:
                    return []
            else:
                # For other entity types, fall back to search with entity_name filter
                return await self.search_entities("", filters={"entity_name": entity_type}, limit=limit)
                
        except Exception as e:
            logger.error(f"Error listing entities of type {entity_type}: {str(e)}")
            return []

    async def search_functions(
        self, query: str, limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for functions via API"""
        payload = {"query": query, "limit": limit}

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

    async def evaluate_function(
        self, function_name: str, args: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Evaluate a function via API"""
        payload = {
            "name": function_name,
            "arguments": args,  # API expects 'arguments' not 'args'
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
                "success": True,
            }
        elif isinstance(data, dict) and "error" not in data:
            if "result" not in data:
                # Wrap raw result
                return {
                    "function": function_name,
                    "args": args,
                    "result": data,
                    "success": True,
                }
            return data
        else:
            error_msg = (
                data.get("error", "Unknown error")
                if isinstance(data, dict)
                else str(data)
            )
            raise FunctionExecutionError(function_name, error_msg)

    async def get_help(
        self, query: str, context: Optional[str] = None, max_depth: int = 3
    ) -> str:
        """Get help via API - with available functions context"""
        try:
            # First, get all available functions to provide context
            functions = await self.list_entities('p8.Function', limit=50)
            
            # Build function context
            function_context = []
            if functions:
                function_context.append("Available functions in the system:")
                for func in functions:
                    name = func.get('name', '')
                    desc = func.get('description', '')
                    params = func.get('parameters', {})
                    if name:
                        function_context.append(f"- {name}: {desc}")
                        if params:
                            function_context.append(f"  Parameters: {params}")
            
            # Combine all context
            full_context = []
            if function_context:
                full_context.append("\n".join(function_context))
            if context:
                full_context.append(context)
            
            combined_context = "\n\n".join(full_context) if full_context else ""
            
            # Search with enhanced context
            search_query = f"{combined_context} {query}" if combined_context else query
            results = await self.search_entities(search_query, limit=max_depth)

            if results and not any("error" in r for r in results if isinstance(r, dict)):
                # Format results as help text
                help_text = []
                for i, result in enumerate(results[:max_depth]):
                    name = result.get("name", f"Result {i+1}")
                    content = result.get("description", result.get("content", ""))
                    if content:
                        help_text.append(f"### {name}\n{content}")

                if help_text:
                    response_parts = []
                    
                    # Add function list if query is about functions
                    if any(keyword in query.lower() for keyword in ['function', 'functions', 'available', 'what can']):
                        if function_context:
                            response_parts.append("## Available Functions\n" + "\n".join(function_context[1:]))
                    
                    # Add search results
                    response_parts.append("## Related Information")
                    response_parts.extend(help_text)
                    
                    return "\n\n".join(response_parts)
            
            # If no results, at least return function list if relevant
            if any(keyword in query.lower() for keyword in ['function', 'functions', 'available', 'what can', 'help']):
                if function_context:
                    return "## Available Functions\n" + "\n".join(function_context[1:])

            return f"I couldn't find specific help for: {query}. Please try rephrasing your question or contact support."
        except Exception as e:
            logger.error(f"Error getting help: {e}")
            return f"Sorry, I encountered an error while searching for help. Error: {str(e)}"

    async def upload_file(
        self,
        file_path: str,
        namespace: Optional[str] = None,
        entity_name: Optional[str] = None,
        task_id: Optional[str] = None,
        description: Optional[str] = None,
        tags: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """Upload file via API"""
        # Check if file exists
        if not os.path.exists(file_path):
            raise FileOperationError(f"File not found: {file_path}", file_path)

        # Detect content type from file extension
        import mimetypes

        content_type, _ = mimetypes.guess_type(file_path)
        if not content_type:
            content_type = "application/octet-stream"  # Default for unknown types

        # Prepare multipart upload
        try:
            with open(file_path, "rb") as f:
                files = {"file": (Path(file_path).name, f, content_type)}
                data = {
                    "add_resource": "true",
                    "namespace": namespace or "p8",
                    "entity_name": entity_name or "Resources",
                }

                # Add optional parameters
                if task_id:
                    data["task_id"] = task_id
                elif description:
                    data["task_id"] = description  # Use description as task_id fallback

                # Use admin upload endpoint
                response = await self.client.post(
                    "/admin/content/upload", files=files, data=data
                )

                result = await self._handle_response(response)

                if "error" not in result:
                    return {
                        "success": True,
                        "file_name": Path(file_path).name,
                        "file_size": os.path.getsize(file_path),
                        **result,
                    }
                else:
                    return {
                        "success": False,
                        "error": result.get("error", "Upload failed"),
                        "file_path": file_path,
                    }
        except Exception as e:
            logger.error(f"Error uploading file: {e}")
            return {"success": False, "error": str(e), "file_path": file_path}

    async def upload_file_content(
        self,
        file_content: str,
        filename: str,
        namespace: Optional[str] = None,
        entity_name: Optional[str] = None,
        task_id: Optional[str] = None,
        description: Optional[str] = None,
        tags: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """Upload file content directly via API"""
        try:
            import io
            import mimetypes

            # Detect content type from filename
            content_type, _ = mimetypes.guess_type(filename)
            if not content_type:
                content_type = (
                    "text/plain"
                    if filename.endswith((".txt", ".md"))
                    else "application/octet-stream"
                )

            # Convert string content to bytes
            file_bytes = file_content.encode("utf-8")
            file_like = io.BytesIO(file_bytes)

            # Prepare multipart upload
            files = {"file": (filename, file_like, content_type)}
            data = {
                "add_resource": "true",
                "namespace": namespace or "p8",
                "entity_name": entity_name or "Resources",
            }

            # Add optional parameters
            if task_id:
                data["task_id"] = task_id
            elif description:
                data["task_id"] = description  # Use description as task_id fallback

            # Use admin upload endpoint
            response = await self.client.post(
                "/admin/content/upload", files=files, data=data
            )

            result = await self._handle_response(response)

            if "error" not in result:
                return {
                    "success": True,
                    "file_name": filename,
                    "file_size": len(file_bytes),
                    **result,
                }
            else:
                return {
                    "success": False,
                    "error": result.get("error", "Upload failed"),
                    "filename": filename,
                }
        except Exception as e:
            logger.error(f"Error uploading file content: {e}")
            return {"success": False, "error": str(e), "filename": filename}

    async def search_resources(
        self, query: str, resource_type: Optional[str] = None, limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Search for resources via API"""
        try:
            # Use TUS search endpoint for files
            params = {"search": query, "limit": limit}

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
        agent: str = None,
        model: str = None,
        session_id: Optional[str] = None,
        stream: bool = True,
    ) -> Union[str, AsyncIterator[str]]:
        """Stream chat response from agent via API"""
        from .config import get_mcp_settings
        settings = get_mcp_settings()
        
        model = model or DEFAULT_MODEL
        agent = agent or settings.default_agent
        
        logger.debug(f"🔍 API stream_chat called with:")
        logger.debug(f"  - query: {query[:100]}...")
        logger.debug(f"  - agent: {agent}")
        logger.debug(f"  - model: {model}")
        logger.debug(f"  - stream: {stream}")
        logger.debug(f"  - session_id: {session_id}")
        
        try:
            import uuid

            # Build the chat completions request
            payload = {
                "model": model,
                "messages": [{"role": "user", "content": query}],
                "stream": stream,
            }

            # Add session ID if provided
            params = {}
            if session_id:
                params["session_id"] = session_id
            else:
                params["session_id"] = str(uuid.uuid4())

            # Use the agent-specific endpoint
            endpoint = f"/chat/agent/{agent}/completions"
            
            logger.debug(f"📡 Making request to: {self.api_endpoint}{endpoint}")
            logger.debug(f"📦 Payload: {payload}")
            logger.debug(f"🔑 Headers: {list(self.headers.keys())}")

            if stream:
                # Return async iterator for streaming
                async def stream_generator():
                    logger.debug(f"🌊 Starting streaming request...")
                    line_count = 0
                    try:
                        async with self.client.stream(
                            "POST", endpoint, json=payload, params=params, timeout=120.0
                        ) as response:
                            logger.debug(f"📨 Response status: {response.status_code}")
                            logger.debug(f"📋 Response headers: {dict(response.headers)}")
                            response.raise_for_status()
                            
                            async for line in response.aiter_lines():
                                if line:
                                    line_count += 1
                                    if line_count <= 5 or line_count % 50 == 0:
                                        logger.debug(f"🔄 Line {line_count}: {line[:100]}...")
                                    yield line
                            
                            logger.debug(f"✅ Stream complete - {line_count} lines received")
                    except Exception as e:
                        logger.error(f"❌ Stream error: {type(e).__name__}: {str(e)}")
                        raise

                return stream_generator()
            else:
                # Return complete response for non-streaming
                response = await self.client.post(
                    endpoint, json=payload, params=params, timeout=120.0
                )
                data = await self._handle_response(response)

                # Extract content from response
                if isinstance(data, dict) and "choices" in data:
                    choices = data.get("choices", [])
                    if choices and len(choices) > 0:
                        message = choices[0].get("message", {})
                        content = message.get("content", "")
                        
                        # Check if there are tool calls but no content
                        if not content and "tool_calls" in message:
                            tool_calls = message.get("tool_calls", [])
                            logger.warning(f"Response contains tool calls but no content. Tool calls: {len(tool_calls)}")
                            return f"[Agent is processing with {len(tool_calls)} tool calls. This may indicate the agent needs more time or the response was incomplete.]"
                        
                        return content
                    else:
                        # No choices in response
                        logger.warning(f"No choices in response: {data}")
                        return f"No response content. Raw data: {data}"
                else:
                    # Return string representation if not in expected format
                    return str(data) if data else "Empty response"

        except Exception as e:
            error_msg = str(e) if str(e) else f"{type(e).__name__}: No error message"
            logger.error(f"Error in stream_chat: {type(e).__name__}: {error_msg}")
            
            # Return error as async iterator for consistency
            async def error_generator():
                yield f'data: {{"error": "{error_msg}"}}\n\n'
                yield "data: [DONE]\n\n"

            return error_generator() if stream else f"Error: {error_msg}"

    async def add_memory(
        self,
        content: str,
        name: Optional[str] = None,
        category: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Add a new memory via API"""
        try:
            payload = {
                "content": content,
                "name": name,
                "category": category,
                "metadata": metadata,
            }
            
            # The user_id is handled by the auth headers
            response = await self.client.post("/memory/add", json=payload)
            return await self._handle_response(response)
        except Exception as e:
            logger.error(f"Failed to add memory: {str(e)}")
            raise APIError(f"Failed to add memory: {str(e)}", endpoint="/memory/add")

    async def list_memories(
        self, limit: int = 50, offset: int = 0
    ) -> List[Dict[str, Any]]:
        """List memories via API"""
        try:
            params = {"limit": limit, "offset": offset}
            response = await self.client.get("/memory/list", params=params)
            data = await self._handle_response(response)
            
            # Extract memories from response
            if isinstance(data, dict) and "memories" in data:
                return data["memories"]
            elif isinstance(data, list):
                return data
            else:
                logger.warning(f"Unexpected response format: {data}")
                return []
        except Exception as e:
            logger.error(f"Failed to list memories: {str(e)}")
            raise APIError(f"Failed to list memories: {str(e)}", endpoint="/memory/list")

    async def get_memory(self, name: str) -> Dict[str, Any]:
        """Get a specific memory by name via API"""
        try:
            response = await self.client.get(f"/memory/get/{name}")
            return await self._handle_response(response)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                raise EntityNotFoundError(name, "UserMemory")
            raise
        except Exception as e:
            logger.error(f"Failed to get memory: {str(e)}")
            raise APIError(f"Failed to get memory: {str(e)}", endpoint=f"/memory/get/{name}")

    async def search_memories(
        self,
        query: Optional[str] = None,
        category: Optional[str] = None,
        limit: int = 50,
    ) -> List[Dict[str, Any]]:
        """Search memories via API"""
        try:
            params = {"limit": limit}
            if query:
                params["query"] = query
            if category:
                params["category"] = category
                
            response = await self.client.get("/memory/search", params=params)
            data = await self._handle_response(response)
            
            # Extract memories from response
            if isinstance(data, dict) and "memories" in data:
                return data["memories"]
            elif isinstance(data, list):
                return data
            else:
                logger.warning(f"Unexpected response format: {data}")
                return []
        except Exception as e:
            logger.error(f"Failed to search memories: {str(e)}")
            raise APIError(f"Failed to search memories: {str(e)}", endpoint="/memory/search")


    async def build_memory(self) -> Dict[str, Any]:
        """Build memory summary via API"""
        try:
            response = await self.client.post("/memory/build")
            return await self._handle_response(response)
        except Exception as e:
            logger.error(f"Failed to build memory: {str(e)}")
            raise APIError(f"Failed to build memory: {str(e)}", endpoint="/memory/build")

    async def close(self):
        """Close the HTTP client"""
        await self.client.aclose()
