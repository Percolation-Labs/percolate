"""
Chat API router that acts as a proxy for language models like OpenAI, Anthropic, and Google.

This module implements a unified API that can:
1. Accept requests in any dialect (OpenAI, Anthropic, Google)
2. Call any model provider using the appropriate format
3. Stream responses using SSE typically but non SSE could be done
4. Provide consistent response format regardless of the underlying language model

Current version is WIP and may not cover the specs entirely but certainly the lowest common denominator should be covered.
The purpose of this implementation is to surface user facing things primarily and any thing else can be logged in the database

This API can be hosted on a user instance to service models registered in their database on behalf of users.

Currently we have implemented only the OpenAI scheme/dialect which most models support. 
There is an argument for implementing anthropic scheme too.

"""

from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Query
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel, Field
import uuid
import time
import json
import asyncio
from typing import Optional, Dict, Any, List, Callable

# Import Percolate modules
from percolate.models.p8 import Task
from percolate.api.routes.auth import get_current_token
import percolate as p8
from percolate.services import ModelRunner
from percolate.services.llm import LanguageModel
from percolate.services.llm.utils import stream_openai_response, stream_anthropic_response, stream_google_response
from percolate.models import MessageStack
from percolate.services.llm.CallingContext import CallingContext
from datetime import datetime
from percolate.utils import logger
import traceback
# Import models from models.py
from .models import (
    CompletionsRequestOpenApiFormat, 
    AnthropicCompletionsRequest,
    GoogleCompletionsRequest,
    CompletionsResponse,
    StreamingCompletionsResponseChunk
)
from percolate.utils.env import POSTGRES_PASSWORD

router = APIRouter()

# ---------------------------------------------------------------------------
# Handler functions for different dialects
# ---------------------------------------------------------------------------

def handle_openai_request(request: CompletionsRequestOpenApiFormat, params: Optional[Dict] = None, language_model_class=LanguageModel):
    """Process an OpenAI format request and return a response."""
    # Extract metadata from request or params
    metadata = extract_metadata(request, params)
    
    # Create a language model instance
    model_name = request.model
    try:
        llm = language_model_class(model_name)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid model: {model_name}. Error: {str(e)}")
    
    # Convert the request into a MessageStack
    message_stack = None
    
    # Handle messages-based format (Chat Completion API)
    if request.messages:
        # Create a MessageStack from the messages
        # Note: For now, we'll extract the last user message as the question
        # and combine any system messages as context
        system_content = ""
        last_user_content = ""
        
        for msg in request.messages:
            if msg.role == "system" and isinstance(msg.content, str):
                system_content += msg.content + "\n"
            elif msg.role == "user" and isinstance(msg.content, str):
                last_user_content = msg.content
        
        # If system message was provided separately
        if request.system and not system_content:
            system_content = request.system
            
        # Create message stack with the last user message as question and system as context
        message_stack = MessageStack(
            question=last_user_content,
            system_prompt=system_content.strip() if system_content else None
        )
    
    # Handle prompt-based format (Legacy Completion API)
    else:
        prompt = request.prompt
        if isinstance(prompt, list):
            prompt = "\n".join(prompt)
            
        # Add system context if provided
        context = None
        if request.system:
            context = request.system
            
        # Create a message stack with the prompt
        message_stack = MessageStack(question=prompt, system_prompt=context)
    
    # Fallback for empty messages/prompt
    if not message_stack:
        message_stack = MessageStack(question="Hello")
    
    # Set up streaming if required
    stream_mode = request.get_streaming_mode(params)
    context = None
    if stream_mode is not None:
        context = CallingContext(
            prefers_streaming=True,
            model=model_name,
            session_id=metadata.get('session_id')
        )
    
    # Make the API call using the raw - at the moment our raw interface takes functions and not tools - they are elevated internally 
    # TODO make this explicit at the interface
    try:
        response = llm._call_raw(
            messages=message_stack,
            functions=request.get_tools_as_functions(),
            context=context
        )
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error calling LLM: {str(e)}")

def handle_anthropic_request(request: CompletionsRequestOpenApiFormat, params: Optional[Dict] = None, language_model_class=LanguageModel):
    """Process an OpenAI format request but call the Anthropic API."""
    # Extract metadata from request or params
    metadata = extract_metadata(request, params)
    
    # Convert OpenAI format to Anthropic format
    anthropic_request = request.to_anthropic_format()
    
    # Create a language model instance with an Anthropic model
    # The model name might need to be adapted to match an Anthropic model name
    model_name = request.model
    if not any(name in model_name.lower() for name in ['claude', 'anthropic']):
        # Use a default Anthropic model if the specified model isn't clearly an Anthropic model
        model_name = "claude-3-5-sonnet-20241022"  # Default to a Claude model
    
    try:
        llm = language_model_class(model_name)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid model: {model_name}. Error: {str(e)}")
    
    # Convert the request into a MessageStack
    message_stack = None
    
    # Handle messages-based format (Chat Completion API)
    if request.messages:
        # Create a MessageStack from the messages
        # Note: For now, we'll extract the last user message as the question
        # and combine any system messages as context
        system_content = ""
        last_user_content = ""
        
        for msg in request.messages:
            if msg.role == "system" and isinstance(msg.content, str):
                system_content += msg.content + "\n"
            elif msg.role == "user" and isinstance(msg.content, str):
                last_user_content = msg.content
        
        # If system message was provided separately
        if request.system and not system_content:
            system_content = request.system
            
        # Create message stack with the last user message as question and system as context
        message_stack = MessageStack(
            question=last_user_content,
            system_prompt=system_content.strip() if system_content else None
        )
    
    # Handle prompt-based format (Legacy Completion API)
    else:
        prompt = request.prompt
        if isinstance(prompt, list):
            prompt = "\n".join(prompt)
            
        # Add system context if provided
        context = None
        if request.system:
            context = request.system
            
        # Create a message stack with the prompt
        message_stack = MessageStack(question=prompt, system_prompt=context)
    
    # Fallback for empty messages/prompt
    if not message_stack:
        message_stack = MessageStack(question="Hello")
    
    # Set up streaming if required
    stream_mode = request.get_streaming_mode(params)
    context = None
    if stream_mode:
        context = CallingContext(
            prefers_streaming=True,
            model=model_name,
            session_id=metadata.get('session_id')
        )
    
    # Make the API call
    try:
        response = llm._call_raw(
            messages=message_stack,
            functions=request.get_tools_as_functions(),
            context=context
        )
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error calling Anthropic LLM: {str(e)}")

def handle_google_request(request: CompletionsRequestOpenApiFormat, params: Optional[Dict] = None, language_model_class=LanguageModel):
    """Process an OpenAI format request but call the Google API."""
    # Extract metadata from request or params
    metadata = extract_metadata(request, params)
    
    # Convert OpenAI format to Google format
    google_request = request.to_google_format()
    model_name = request.model
    try:
        llm = language_model_class(model_name)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid model: {model_name}. Error: {str(e)}")
    
    # Convert the request into a MessageStack
    message_stack = None
    
    # Handle messages-based format (Chat Completion API)
    if request.messages:
        # Create a MessageStack from the messages
        # Note: For now, we'll extract the last user message as the question
        # and combine any system messages as context
        system_content = ""
        last_user_content = ""
        
        for msg in request.messages:
            if msg.role == "system" and isinstance(msg.content, str):
                system_content += msg.content + "\n"
            elif msg.role == "user" and isinstance(msg.content, str):
                last_user_content = msg.content
        
        # If system message was provided separately
        if request.system and not system_content:
            system_content = request.system
            
        # Create message stack with the last user message as question and system as context
        message_stack = MessageStack(
            question=last_user_content,
            system_prompt=system_content.strip() if system_content else None
        )
    
    # Handle prompt-based format (Legacy Completion API)
    else:
        prompt = request.prompt
        if isinstance(prompt, list):
            prompt = "\n".join(prompt)
            
        # Add system context if provided
        context = None
        if request.system:
            context = request.system
            
        # Create a message stack with the prompt
        message_stack = MessageStack(question=prompt, system_prompt=context)
    
    # Fallback for empty messages/prompt
    if not message_stack:
        message_stack = MessageStack(question="Hello")
    
    # Set up streaming if required
    stream_mode = request.get_streaming_mode(params)
    context = None
    if stream_mode:
        context = CallingContext(
            prefers_streaming=True,
            model=model_name,
            session_id=metadata.get('session_id')
        )
    
    # Make the API call
    try:
        response = llm._call_raw(
            messages=message_stack,
            functions=request.get_tools_as_functions(),
            context=context
        )
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error calling Google LLM: {str(e)}")

# ---------------------------------------------------------------------------
# Streaming handler functions
# ---------------------------------------------------------------------------

async def fake_data_streamer():
    """for control test we keep this one"""
    try:
        for i in range(10):
            yield b'some fake data\n\n'
            await asyncio.sleep(0.5)
    except:
        pass
    finally:
        print('DONE WITH FAKES')

def map_delta_to_canonical_format(data, dialect, model):
    """
    Map a streaming delta chunk to canonical format based on the provider dialect.
    
    This helper function converts streaming chunks from different providers
    (OpenAI, Anthropic, Google) into a consistent OpenAI delta format for client consumption.
    
    The output format matches the OpenAI delta format:
    ```
    {
        "id": "chatcmpl-123",
        "object": "chat.completion.chunk",
        "created": 1677858242,
        "model": "gpt-4",
        "choices": [{
            "index": 0,
            "delta": {
                "content": " is"  // or tool_calls for tool use
            },
            "finish_reason": null
        }]
    }

    
    ```
    
    function calls
    ```
    {"id":"chatcmpl-BJmlj0fi7Bhan8p48XRMojmVTGpxv",
    "object":"chat.completion.chunk",
    "created":1744055399,
    "model":"gpt-4o-mini-2024-07-18",
    "service_tier":"default",
    "system_fingerprint":"fp_86d0290411",
    "choices":[{"index":0,
    "delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"}"}}]},
    "logprobs":null,"finish_reason":null}],
    "usage":null}
    ```
    
    Args:
        data: The raw response data chunk
        dialect: The LLM provider dialect ('openai', 'anthropic', 'google')
        model: The model name
        
    Returns:
        Dict with data converted to canonical format with delta structure
    """
    # Use the StreamingCompletionsResponseChunk class methods to handle the conversion
    from .models import StreamingCompletionsResponseChunk
    
    # This delegates the mapping logic to the appropriate method based on the dialect
    return StreamingCompletionsResponseChunk.map_to_canonical_format(data, dialect, model)

def stream_generator(response, stream_mode, audit_callback=None, from_dialect='openai', model=None):
    """
    Stream the LLM response to the client, converting chunks to canonical format and make sure to encode binary "lines"
    
    Args:
        response: The LLM response object (from LanguageModel.__call__)
        stream_mode: The streaming mode ('sse' or 'standard')
        audit_callback: Optional callback to run after streaming completes
        dialect: The API dialect ('openai', 'anthropic', or 'google')
        model: The model name
    """
    
    collected_chunks = []
    for chunk in response.iter_lines():
        """add the decoded lines for later processing"""
        collected_chunks.append(chunk.decode('utf-8'))
        
        """
        this is convenience that comes at a cost - the user is essentially using all models in the open ai format so we must do some parsing
        TODO: think more about this
        """
        if from_dialect and from_dialect != 'openai':
            json_data = chunk.decode('utf-8')[6:]
            if json_data and json_data[0] == '{':       
                """Parse in valid data and use the canonical mapping"""     
                canonical_data = map_delta_to_canonical_format(json.loads(json_data), from_dialect, model)
             
                """recover the SSE binary format"""
                chunk = f"data: {json.dumps(canonical_data)}\n\n".encode('utf-8')
        
        """this should always be the case for properly streaming lines on the client for SSE"""
        if not chunk.endswith(b'\n\n'):
            chunk = chunk + b'\n\n'
        
        print(chunk)
        yield chunk
               
    if audit_callback:
        full_response = "".join(collected_chunks)
        audit_callback(full_response)
               
 
def extract_metadata(request, params=None):
    """
    Extract metadata from request and params.
    
    Args:
        request: The API request object
        params: Optional additional parameters
        
    Returns:
        dict: Combined metadata
    """
    metadata = {}
    
    # Extract from request metadata if available
    if hasattr(request, 'metadata') and request.metadata:
        metadata.update(request.metadata)
    
    # Extract from params if available
    if params:
        for key in ['user_id', 'session_id', 'channel_id', 'channel_type', 'api_provider', 'use_sse']:
            if key in params:
                metadata[key] = params[key]
    
    # Generate session_id if not provided
    if 'session_id' not in metadata:
        metadata['session_id'] = str(uuid.uuid4())
    
    return metadata

def audit_request(request, response, metadata=None):
    """
    Audit the request and response in the database.
    This is a placeholder for the actual implementation.
    
    Args:
        request: The original request
        response: The LLM response
        metadata: Additional metadata
    """
    # TODO: Implement actual database auditing
    # For now, just print
    print(f"AUDIT: Request to {request.model} with metadata {metadata}")
    print(f"AUDIT: Response received with {getattr(response, 'tokens_out', 'unknown')} tokens")

# ---------------------------------------------------------------------------
# API Endpoints
# ---------------------------------------------------------------------------


    
@router.post("/completions")
async def completions(
    request: CompletionsRequestOpenApiFormat,
    background_tasks: BackgroundTasks,
    user_id: Optional[str] = Query(None, description="ID of the end user making the request"),
    session_id: Optional[str] = Query(None, description="ID for grouping related interactions"),
    channel_id: Optional[str] = Query(None, description="ID of the channel where the interaction happens"),
    channel_type: Optional[str] = Query(None, description="Type of channel (e.g., slack, web, etc.)"),
    api_provider: Optional[str] = Query(None, description="Override the default provider"),
    #use_sse: Optional[bool] = Query(False, description="Whether to use Server-Sent Events for streaming"),
    token: dict = Depends(get_current_token)
):
    """
    Use any model via an OpenAI API format and get model completions as streaming or non-streaming.
    
    This endpoint can:
    - Accept requests in OpenAI format
    - Call any LLM provider (OpenAI, Anthropic, Google)
    - Stream responses with SSE or standard streaming
    - Provide consistent response format
    """
    
    # Check for valid bearer token - this is a temp test key
    
    expected_token = "!p3rc0la8!" #<-this a testing idea
    expected_token = POSTGRES_PASSWORD #<-this will be the secure bearer for now but we could relax to an api key
    
    token = request.bearer_token or token
    if not token:
        logger.warning(f"No bearer - not authenticated")
        raise HTTPException(status_code=401, detail="API token is missing")
    if token != expected_token:
        logger.warning(f"{token} != {expected_token} - not authenticated")
        raise HTTPException(status_code=401, detail="API token is incorrect")
    
    #print(request.stream)
    try:
        # Collect query parameters into a dict for easier handling
        params = {
            'user_id': user_id,
            'session_id': session_id,
            'channel_id': channel_id,
            'channel_type': channel_type,
            'api_provider': api_provider
        }
        
        # Remove None values
        params = {k: v for k, v in params.items() if v is not None}
        
        # Determine the dialect based on model or explicit api_provider parameter
        dialect = request.get_dialect(params)
        
        # Determine streaming mode
        stream_mode = request.get_streaming_mode(params)
        
        # Select the appropriate handler based on dialect
        if dialect == 'anthropic':
            handler = handle_anthropic_request
        elif dialect == 'google':
            handler = handle_google_request
        else:
            handler = handle_openai_request
        
        # Process the request using the selected handler
        response = handler(request, params)
        
        # Extract metadata for auditing
        metadata = extract_metadata(request, params)
        
        # Handle streaming vs non-streaming responses
        if stream_mode:
            # For streaming responses, use StreamingResponse with appropriate media type
            media_type = "text/event-stream" #if stream_mode == 'sse' else "text/plain"
            
            # Create an audit callback for when streaming completes
            def audit_callback(full_response):
                audit_request(request, full_response, metadata)
                    
            return StreamingResponse(
                stream_generator(
                    response=response,
                    stream_mode=stream_mode,
                    audit_callback=audit_callback,
                    from_dialect=dialect,  # Pass dialect for canonical format mapping
                    model=request.model  # Pass model name
                ),
                media_type=media_type
            )
        else:
            if background_tasks:
                # For non-streaming, add auditing as a background task
                background_tasks.add_task(audit_request, request, response, metadata)
            
            return JSONResponse(content=response.json(), status_code=response.status_code)
    except HTTPException:
        
        logger.warning(traceback.format_exc())
        raise
    except:
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=400, detail=f"Something happened that should not have happened.")
    

@router.post("/anthropic/completions")
async def anthropic_completions(
    request: AnthropicCompletionsRequest,
    background_tasks: BackgroundTasks,
    user: dict = Depends(get_current_token)
):
    """
    Use Anthropic's API format to call any model provider.
    
    This endpoint accepts requests in Anthropic's Claude API format
    and converts them to the appropriate format for the target provider.
    """
    # Convert Anthropic format to OpenAI format
    openai_format = request.to_openai_format()
    
    # Create an OpenAI format request
    openai_request = CompletionsRequestOpenApiFormat(
        model=request.model,
        prompt=openai_format.get("prompt"),
        max_tokens=openai_format.get("max_tokens"),
        temperature=openai_format.get("temperature"),
        top_p=openai_format.get("top_p"),
        stop=openai_format.get("stop"),
        stream=request.stream,
        metadata=request.metadata
    )
    
    # Use the standard completions endpoint to handle it
    return await completions(openai_request, background_tasks, user=user)

@router.post("/google/completions")
async def google_completions(
    request: GoogleCompletionsRequest,
    background_tasks: BackgroundTasks,
    user: dict = Depends(get_current_token)
):
    """
    Use Google's API format to call any model provider.
    
    This endpoint accepts requests in Google's Gemini API format
    and converts them to the appropriate format for the target provider.
    """
    # Convert Google format to OpenAI format
    openai_format = request.to_openai_format()
    
    # Create an OpenAI format request
    openai_request = CompletionsRequestOpenApiFormat(
        model=openai_format.get("model", "gemini-1.5-flash"),
        prompt=openai_format.get("prompt"),
        max_tokens=openai_format.get("max_tokens"),
        temperature=openai_format.get("temperature"),
        top_p=openai_format.get("top_p"),
        stop=openai_format.get("stop"),
        stream=False,  # Google uses a different streaming approach
        metadata=request.metadata
    )
    
    # Use the standard completions endpoint to handle it
    return await completions(openai_request, background_tasks, user=user)

@router.post("/agent/{agent}/completions")
async def agent_completions(
    request: CompletionsRequestOpenApiFormat,
    agent: str,
    background_tasks: BackgroundTasks,
    user: dict = Depends(get_current_token)
):
    """
    Use any model with a specific Percolate agent and get model completions.
    
    If the agent is used for processing server-side, this endpoint will:
    - Return streaming responses if streaming is enabled
    - Return a callback ID for polling if streaming is disabled
    """
    # Extract metadata
    metadata = extract_metadata(request)
    session_id = metadata.get("session_id", str(uuid.uuid4()))
    
    # Determine streaming mode
    stream_mode = request.get_streaming_mode()
    
    # Create a Percolate agent
    try:
        percolate_agent = p8.Agent(p8.load_model(agent))
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to load agent '{agent}': {str(e)}")
    
    # Extract prompt
    prompt = request.prompt
    if isinstance(prompt, list):
        prompt = "\n".join(prompt)
    
    if stream_mode:
        # For streaming, we run the agent and stream the results
        # TODO: Implement actual streaming of agent responses
        async def agent_stream_generator():
            try:
                response = percolate_agent.run(prompt, language_model=request.model)
                if stream_mode == 'sse':
                    yield f"data: {json.dumps(response)}\n\n"
                else:
                    yield json.dumps(response)
            except Exception as e:
                if stream_mode == 'sse':
                    yield f"data: {json.dumps({'error': str(e)})}\n\n"
                else:
                    yield json.dumps({'error': str(e)})
        
        media_type = "text/event-stream" if stream_mode == 'sse' else "application/json"
        return StreamingResponse(agent_stream_generator(), media_type=media_type)
    else:
        # For non-streaming, we run in the background and return a callback ID
        callback_id = f"agent_task_{uuid.uuid4()}"
        
        # Start the agent in the background
        background_tasks.add_task(
            run_agent_in_background,
            percolate_agent,
            prompt,
            request.model,
            callback_id,
            session_id
        )
        
        # Return the callback ID for polling
        return JSONResponse(content={
            "id": callback_id,
            "status": "processing",
            "message": "Agent is processing your request. Use the poll-completions endpoint to check for results."
        })

async def run_agent_in_background(agent, prompt, model, callback_id, session_id):
    """Run an agent in the background and store results for polling."""
    try:
        # Run the agent
        result = agent.run(prompt, language_model=model)
        
        # Store the result in the database or cache for polling
        # TODO: Implement storing results in database/cache
        
        print(f"COMPLETED AGENT TASK {callback_id} FOR SESSION {session_id}")
        print(f"RESULT: {result}")
    except Exception as e:
        # Store the error for polling
        print(f"FAILED AGENT TASK {callback_id}: {str(e)}")

@router.get("/agent/{agent}/poll-completions/{callback_id}")
async def poll_agent_completions(
    callback_id: str,
    agent: str,
    user: dict = Depends(get_current_token)
):
    """
    Poll for results from an agent running in the background.
    
    This endpoint is paired with agent_completions for checking the status
    of background agent tasks.
    """
    # TODO: Implement actual retrieval of results from database/cache
    
    # For now, return a mock response
    return JSONResponse(content={
        "id": callback_id,
        "status": "completed",
        "result": {
            "content": "This is a placeholder response. Implement actual result retrieval."
        }
    })

class SimpleAskRequest(BaseModel):
    """Request model for a simple question to an agent."""
    model: Optional[str] = Field(None, description="The language model to use - Percolate defaults to GPT models")
    question: str = Field(..., description="A simple question to ask")
    agent: Optional[str] = Field(None, description="The configured agent - the Percolate agent will be used by default to answer generic questions")
    max_iteration: Optional[int] = Field(3, description="The agent runs loops - for simple ask fewer is better")
    stream: Optional[bool] = Field(False, description="Whether to stream the response")
    
@router.post("/")
async def ask(
    request: SimpleAskRequest,
    background_tasks: BackgroundTasks,
    user: dict = Depends(get_current_token)
):
    """
    A simple ask request using any percolate agent and language model.
    
    This endpoint is a simplified way to use Percolate agents for question answering.
    """
    # Use default agent if not specified
    agent_name = request.agent or "default"
    
    try:
        # Load the agent
        agent = p8.Agent(p8.load_model(agent_name))
        
        # Run the agent with the question
        result = agent.run(
            request.question,
            language_model=request.model,
            max_iterations=request.max_iteration
        )
        
        # Audit in the background
        background_tasks.add_task(
            audit_request,
            request,
            result,
            {"agent": agent_name}
        )
        
        return JSONResponse(content=result)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error running agent: {str(e)}")