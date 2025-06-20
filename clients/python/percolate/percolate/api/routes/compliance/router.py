"""
Compliance router for OpenAI API compatibility.
Provides /v1 endpoints that mirror OpenAI's API structure.
This router is excluded from Swagger documentation.
"""

from fastapi import APIRouter, Depends, Request, Response, BackgroundTasks, Query
from fastapi.responses import StreamingResponse
import os
import json
import re
from typing import Optional

from ..auth import hybrid_auth, require_user_auth
from ..chat.router import completions, agent_completions
from ..chat.models import CompletionsRequestOpenApiFormat
from ...utils.models import list_available_models
from percolate.utils import logger

# Get the model filter from environment variable
MODELS_FILTER = os.environ.get("P8_MODELS_FILTER", "").split(",") if os.environ.get("P8_MODELS_FILTER") else None

# def try_extract_chat_id_from_openwebui(request: Request) -> Optional[str]:
#     """
#     Attempts to extract a chat ID from the OpenWebUI origin/referer headers.
    
#     OpenWebUI sometimes sends requests from URLs like:
#     https://ask-one.resmagic.io/api/v1/chats/a6b84bfa-1d28-43a0-912f-ae253205575f
    
#     This function extracts the UUID after 'chats/' to use as the chat_id.
    
#     Args:
#         request: The FastAPI request object with headers
        
#     Returns:
#         Optional[str]: The extracted chat ID if found, None otherwise
#     """
#     # Get headers that might contain the chat ID
#     origin = request.headers.get("origin")
#     referer = request.headers.get("referer")
#     host = request.headers.get("host")
    
#     logger.debug(f"{origin=} {referer=}")
    
#     # Define regex pattern to extract UUIDs after "chats/"
#     pattern = r"/chats/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})"
    
#     # Try to find match in referer first (most likely location)
#     if referer:
#         match = re.search(pattern, referer)
#         if match:
#             logger.info(f"Extracted chat ID from referer: {match.group(1)}")
#             return match.group(1)
    
#     # Then try origin if referer didn't match
#     if origin:
#         match = re.search(pattern, origin)
#         if match:
#             logger.info(f"Extracted chat ID from origin: {match.group(1)}")
#             return match.group(1)
            
#     # No chat ID found in headers
#     return None

def try_get_chat_id_by_multiple_methods(request_obj, raw_request: Request, session_id: Optional[str] = None) -> Optional[str]:
    """
    Tries multiple methods to get a chat ID, in order of precedence:
    1. Use provided session_id if available
    2. Get chat_id from request object
    3. Get chat_id from request metadata
    4. Extract chat_id from OpenWebUI headers
    
    Args:
        request_obj: The API request object (CompletionsRequestOpenApiFormat)
        raw_request: The FastAPI Request object with headers
        session_id: Optional session ID from query params
        
    Returns:
        Optional[str]: The effective chat ID to use, or None if not found
        
    Side effects:
        - If a chat ID is found from headers, it's added to request_obj.metadata
    """
    # Start with provided session_id
    effective_id = session_id
    source = None
    
    # Try to get chat_id from request object
    if not effective_id and hasattr(request_obj, 'chat_id') and request_obj.chat_id:
        effective_id = request_obj.chat_id
        source = "request.chat_id"
        
        # Ensure metadata exists and add chat_id to it
        if not hasattr(request_obj, 'metadata') or request_obj.metadata is None:
            request_obj.metadata = {}
        request_obj.metadata['chat_id'] = effective_id
        
    # Try to get chat_id from metadata
    elif not effective_id and hasattr(request_obj, 'metadata') and request_obj.metadata and 'chat_id' in request_obj.metadata:
        effective_id = request_obj.metadata['chat_id']
        source = "request.metadata.chat_id"
        
    # Try to extract chat_id from OpenWebUI origin/referer headers
    # elif not effective_id:
    #     extracted_id = try_extract_chat_id_from_openwebui(raw_request)
    #     if extracted_id:
    #         effective_id = extracted_id
    #         source = "openwebui_headers"
            
    #         # Ensure metadata exists and add chat_id to it
    #         if not hasattr(request_obj, 'metadata') or request_obj.metadata is None:
    #             request_obj.metadata = {}
    #         request_obj.metadata['chat_id'] = extracted_id
    
    if effective_id:
        logger.debug(f"Using chat_id from {source}: {effective_id}")
    
    return effective_id

# Create router without Swagger documentation
router = APIRouter(include_in_schema=False)

# Models endpoint - unauthenticated
@router.get("/models")
async def v1_models():
    """List available models - unauthenticated endpoint for OpenAI compatibility"""
    models_response = list_available_models()
    
    # Apply filter if specified
    if MODELS_FILTER:
        models_response['data'] = [
            model for model in models_response['data'] 
            if model['id'] in MODELS_FILTER
        ]
    
    return models_response

# Chat completions endpoint - requires authentication
@router.post("/chat/completions")
async def v1_chat_completions(
    request: CompletionsRequestOpenApiFormat,
    raw_request: Request,
    user_id: Optional[str] = Depends(hybrid_auth),
    session_id: Optional[str] = Query(None, description="ID for grouping related interactions")
):
    """Chat completions endpoint for OpenAI compatibility"""
    # Get effective chat ID using our helper function
    effective_session_id = try_get_chat_id_by_multiple_methods(request, raw_request, session_id)
    
    return await completions(
        request=request, 
        background_tasks=None, 
        user_id=user_id,
        session_id=effective_session_id
    )

# Agent-specific models endpoint - unauthenticated
@router.get("/agents/{agent_id_or_name}/models")
async def v1_agent_models(agent_id_or_name: str):
    """List models available for a specific agent"""
    # Map 'default' to the Percolate agent
    if agent_id_or_name == 'default':
        agent_id_or_name = 'p8-PercolateAgent'
    
    # For now, return the same models as the general endpoint
    # In the future, this could filter based on agent capabilities
    models_response = list_available_models()
    
    # Apply filter if specified
    if MODELS_FILTER:
        models_response['data'] = [
            model for model in models_response['data'] 
            if model['id'] in MODELS_FILTER
        ]
    
    # Add agent context to the response
    for model in models_response['data']:
        if 'metadata' not in model:
            model['metadata'] = {}
        model['metadata']['agent_id'] = agent_id_or_name
    
    return models_response

# Agent-specific chat completions - requires authentication
@router.post("/agents/{agent_id_or_name}/chat/completions")
async def v1_agent_chat_completions(
    agent_id_or_name: str,
    request: CompletionsRequestOpenApiFormat,
    raw_request: Request,  # Add FastAPI Request object to access raw request data
    background_tasks: BackgroundTasks = None,
    user_id: str = Depends(hybrid_auth),  # Must have user context
    session_id: Optional[str] = Query(None, description="ID for grouping related interactions"),
    channel_id: Optional[str] = Query(None, description="ID of the channel where the interaction happens"),
    channel_type: Optional[str] = Query(None, description="Type of channel (e.g., slack, web, etc.)"),
    api_provider: Optional[str] = Query(None, description="Override the default provider"),
    is_audio: Optional[bool] = Query(False, description="Client asks to decoded base 64 audio using a model"),
    device_info: Optional[str] = Query(None, description="Device info Base64 encoded with arbitrary parameters such as GPS"),
    auth_user_id: Optional[str] = Depends(hybrid_auth)
):
    """Agent-specific chat completions endpoint"""
    
    # Map 'default' to the Percolate agent
    if agent_id_or_name == 'default':
        agent_id_or_name = 'p8-PercolateAgent'
    
    # Add agent context to the request
    if not hasattr(request, 'metadata') or request.metadata is None:
        request.metadata = {}
    request.metadata['agent_id'] = agent_id_or_name
    
    # Get effective chat ID using our helper function
    effective_session_id = try_get_chat_id_by_multiple_methods(request, raw_request, session_id)
   
    return await agent_completions(
        request=request,
        background_tasks=background_tasks,
        agent_name=agent_id_or_name,
        user_id=user_id,
        session_id=effective_session_id,
        channel_id=channel_id,
        channel_type=channel_type,
        api_provider=api_provider,
        is_audio=is_audio,
        device_info=device_info,
        auth_user_id=auth_user_id
    )

# Support for base paths like /v1/ and /v1/agents/{agent_id}/
# These return basic API information
@router.get("/")
async def v1_root():
    """Root endpoint for v1 API"""
    return {
        "version": "v1",
        "description": "OpenAI-compatible API",
        "endpoints": [
            "/v1/models",
            "/v1/chat/completions",
            "/v1/agents/{agent_id_or_name}/models",
            "/v1/agents/{agent_id_or_name}/chat/completions"
        ]
    }

@router.get("/agents/{agent_id_or_name}")
async def v1_agent_root(agent_id_or_name: str):
    """Agent-specific root endpoint"""
    # Map 'default' to the Percolate agent
    display_name = agent_id_or_name
    if agent_id_or_name == 'default':
        display_name = 'p8-PercolateAgent (default)'
    
    return {
        "version": "v1",
        "agent_id": agent_id_or_name,
        "description": f"OpenAI-compatible API for agent {display_name}",
        "endpoints": [
            f"/v1/agents/{agent_id_or_name}/models",
            f"/v1/agents/{agent_id_or_name}/chat/completions"
        ]
    }