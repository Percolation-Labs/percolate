"""
Compliance router for OpenAI API compatibility.
Provides /v1 endpoints that mirror OpenAI's API structure.
This router is excluded from Swagger documentation.
"""

from fastapi import APIRouter, Depends, Request, Response, BackgroundTasks, Query
from fastapi.responses import StreamingResponse
import os
from typing import Optional

from ..auth import hybrid_auth, require_user_auth
from ..chat.router import completions, agent_completions
from ..chat.models import CompletionsRequestOpenApiFormat
from ...utils.models import list_available_models

# Get the model filter from environment variable
MODELS_FILTER = os.environ.get("P8_MODELS_FILTER", "").split(",") if os.environ.get("P8_MODELS_FILTER") else None

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
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """Chat completions endpoint for OpenAI compatibility"""
    return await completions(request, background_tasks=None, user_id=user_id)

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
    
    # Pass through to the agent_completions endpoint with the proper agent name
    return await agent_completions(
        request=request,
        background_tasks=background_tasks,
        agent_name=agent_id_or_name,
        user_id=user_id,
        session_id=session_id,
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