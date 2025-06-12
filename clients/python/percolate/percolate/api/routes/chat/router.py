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


Some implementations like OpenWebUI send X-headers for JWT like data and metadata 

open-webui/backend/open_webui/utils/chat.py, the chat ID is included in line 211:
    "metadata": {
      **(request.state.metadata if hasattr(request.state, "metadata") else {}),
      "task": str(TASKS.TITLE_GENERATION),
      "task_body": form_data,
      "chat_id": form_data.get("chat_id", None),
  },
  

"""

from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Query, Path
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel, Field
import uuid
import time
import json
import asyncio
from typing import Optional, Dict, Any, List, Callable

# Import Percolate modules
from percolate.models.p8 import Task
from percolate.api.routes.auth import get_current_token, hybrid_auth, require_user_auth
import percolate as p8
from percolate.services import ModelRunner
from percolate.services.llm import LanguageModel
from percolate.services.llm.utils import stream_openai_response, stream_anthropic_response, stream_google_response
from percolate.models import MessageStack
from percolate.services.llm.CallingContext import CallingContext
from datetime import datetime
from percolate.utils import logger
from percolate.models import Session, User,AIResponse
from percolate.utils import make_uuid
from percolate.services import ModelCache

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

def get_messages_by_role_from_request(request:CompletionsRequestOpenApiFormat, metadata:dict):
    """"""
    from percolate.services.llm.utils import audio_to_text
    system_content = ""
    last_user_content = ""
    
    # logger.debug(f"**********************\n")
    # logger.debug(request.model_dump())
    # logger.debug(f"**********************\n")
        
    # Handle messages-based format (Chat Completion API)
    if request.messages:
        # Create a MessageStack from the messages
        # Note: For now, we'll extract the last user message as the question
        # and combine any system messages as context

        is_audio = False
        if is_audio:= metadata.get('is_audio'):
            """TODO: we only support this on the open ai handler for now as its experimental - not sure how we want to deal with transcription inline"""
            logger.info(f"is_audio set so we will assume ALL user content is based 64 audio")
      
        for msg in request.messages:
            """TODO - there is some cases where we might want to add assistant responses e.g. from OpenWebUI"""
            if msg.role == "system" and isinstance(msg.content, str):
                system_content += msg.content + "\n"
            elif msg.role == "user" and isinstance(msg.content, str):
                """its not clear if we should merge user messages"""
                last_user_content += msg.content + "\n"
                if is_audio:
                    try:
                        logger.info(f'transcribing supposed based 64 encoded audio content - {last_user_content[:10]}...{last_user_content[-10:]}')
                        last_user_content = audio_to_text(last_user_content)['text']
                        metadata['transcribed_audio'] = last_user_content
                    except:
                        logger.warning(f"Failed to transcribe and we will let the language model handle it or not for now - {traceback.format_exc()}") 

    return system_content, last_user_content

def handle_agent_request(request: CompletionsRequestOpenApiFormat, params: Optional[Dict] = None, language_model_class=LanguageModel, agent_model_name:str=None):
    """
    Handle agent requests in both streaming and non-streaming modes.
    
    This function handles:
    1. Loading the appropriate agent model (using ModelCache)
    2. Setting up the context with user info and system content
    3. Streaming or non-streaming response based on request.stream flag
    
    Args:
        request: The completion request in OpenAI format
        params: Optional parameters including user ID, session ID, etc.
        language_model_class: The language model class to use
        agent_model_name: The name of the agent model to load
        
    Returns:
        If streaming: A stream iterator that yields SSE chunks
        If non-streaming: A complete response object in the requested format
    """
    from percolate.models import Resources
    from percolate.services.llm.proxy.stream_generators import collect_stream_to_response
    from percolate.services.llm.proxy.models import OpenAIResponse
    
    # Extract metadata and prepare context
    metadata = params or {} 
    system_content, query = get_messages_by_role_from_request(request, params)
    
    # Ensure agent_model_name has proper format
    if agent_model_name:
        # Replace hyphens with dots for web-friendly URLs
        if '-' in agent_model_name:
            agent_model_name = agent_model_name.replace('-', '.')
            
        # Ensure agent name has a namespace if needed
        if '.' not in agent_model_name:
            logger.warning(f"Agent name '{agent_model_name}' does not have a namespace. Will try to load as is, but this might cause issues.")
    
    # Get a ModelRunner from cache or create a new one
    # This ensures we reuse fully initialized ModelRunner instances
    userid = metadata.get('userid') or metadata.get('user_id')
    
    # Import directly from the module to avoid any import issues
    from percolate.services.ModelRunnerCache import get_runner, get_runner_cache_stats
    
    # Log cache stats before access
    logger.info(f"ModelRunnerCache stats before access: {get_runner_cache_stats()}")
    
    # Standardize agent_model_name format
    if agent_model_name and '-' in agent_model_name:
        agent_model_name = agent_model_name.replace('-', '.')
    
    # Get or create a ModelRunner with user context
    runner = get_runner(
        agent_model_name or "p8.Resources",
        user_id=userid,
        # Add any other user context needed for row-level security
        fallback_to_resources=True
    )
    
    # Log cache stats after access
    logger.info(f"ModelRunnerCache stats after access: {get_runner_cache_stats()}")
    
    # The runner is our fully initialized agent
    agent = runner
    
    # Construct context with user info and session ID
    userid = metadata.get('userid') or metadata.get('user_id')
    
    # Use existing session_id if available (which might come from chat_id)
    # Otherwise generate a new one
    session_id = metadata.get('session_id') or str(uuid.uuid1())
    
    ctx = CallingContext(
        plan=system_content,
        username=userid, 
        session_id=session_id, 
        channel_ts=metadata.get('channel_ts') or session_id
    )
    
    for key, value in metadata.items():
        if key not in ['userid', 'user_id', 'session_id', 'channel_ts'] and value:
            if hasattr(ctx, key) and value:
                setattr(ctx, key, value)
    
    stream = agent.stream(query, context=ctx)
    
    if request.stream:
        return stream
    
    return collect_stream_to_response(
            stream,
            source_scheme='openai',
            target_scheme='openai',
            model=request.model
        )
    
def handle_openai_request(request: CompletionsRequestOpenApiFormat, params: Optional[Dict] = None, language_model_class=LanguageModel):
    """Process an OpenAI format request and return a response.
    
    we are checking of this is audio and we do inline transcription
    """
    from percolate.services.llm.utils import audio_to_text
    # Extract metadata from request or params
    metadata = params or {}#extract_metadata(request, params)
    
    is_audio = metadata.get('is_audio') or False
    if is_audio:
        """TODO: we only support this on the open ai handler for now as its experimental - not sure how we want to deal with transcription inline"""
        logger.info(f"is_audio set so we will assume ALL user content is based 64 audio. {metadata=}")
     
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
                if is_audio:
                    try:
                        logger.info(f'transcribing supposed based 64 encoded audio content - {last_user_content[:10]}...{last_user_content[-10:]}')
                        last_user_content = audio_to_text(last_user_content)['text']
                        metadata['transcribed_audio'] = last_user_content
                    except:
                        logger.warning(f"Failed to transcribe and we will let the language model handle it or not for now - {traceback.format_exc()}") 
        
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
        # Use existing session_id if available (which might come from chat_id)
        # Otherwise use the one in metadata or generate a new one
        session_id = metadata.get('session_id') or str(uuid.uuid1())
        
        context = CallingContext(
            prefers_streaming=True,
            model=model_name,
            session_id=session_id,
            username=metadata.get('userid') or metadata.get('user_id'),
            channel_ts=metadata.get('channel_ts') or session_id
        )
        
        # Add any other metadata fields to the context
        for key, value in metadata.items():
            if key not in ['session_id', 'userid', 'user_id', 'channel_ts'] and value:
                # Only set if the attribute exists on CallingContext
                if hasattr(context, key) and value:
                    setattr(context, key, value)
    
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
        # Use existing session_id if available (which might come from chat_id)
        # Otherwise use the one in metadata or generate a new one
        session_id = metadata.get('session_id') or str(uuid.uuid1())
        
        context = CallingContext(
            prefers_streaming=True,
            model=model_name,
            session_id=session_id,
            username=metadata.get('userid') or metadata.get('user_id'),
            channel_ts=metadata.get('channel_ts') or session_id
        )
        
        # Add any other metadata fields to the context
        for key, value in metadata.items():
            if key not in ['session_id', 'userid', 'user_id', 'channel_ts'] and value:
                # Only set if the attribute exists on CallingContext
                if hasattr(context, key) and value:
                    setattr(context, key, value)
    
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
        # Use existing session_id if available (which might come from chat_id)
        # Otherwise use the one in metadata or generate a new one
        session_id = metadata.get('session_id') or str(uuid.uuid1())
        
        context = CallingContext(
            prefers_streaming=True,
            model=model_name,
            session_id=session_id,
            username=metadata.get('userid') or metadata.get('user_id'),
            channel_ts=metadata.get('channel_ts') or session_id
        )
        
        # Add any other metadata fields to the context
        for key, value in metadata.items():
            if key not in ['session_id', 'userid', 'user_id', 'channel_ts'] and value:
                # Only set if the attribute exists on CallingContext
                if hasattr(context, key) and value:
                    setattr(context, key, value)
    
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

def stream_generator(response, stream_mode, audit_callback=None, from_dialect='openai', model=None, agent_name=None):
    """
    Stream the LLM response to the client, converting chunks to canonical format and make sure to encode binary "lines"
    
    Args:
        response: The LLM response object (from LanguageModel.__call__)
        stream_mode: The streaming mode ('sse' or 'standard')
        audit_callback: Optional callback to run after streaming completes
        from_dialect: The API dialect ('openai', 'anthropic', or 'google')
        model: The model name
        agent_name: The name of the agent being used (for agent completions)
    """
    
    collected_chunks = []
    done_marker_seen = False
    
    try:
        # Optimization: Send only a single minimal heartbeat to establish connection
        # This reduces initial latency before content starts flowing
        heartbeat = {
            "id": str(uuid.uuid4()),
            "object": "chat.completion.chunk",
            "choices": [{
                "index": 0,
                "delta": {"content": ""},
                "finish_reason": None
            }]
        }
        yield f'data: {json.dumps(heartbeat)}\n\n'.encode('utf-8')
        
        """TODO: Percolate agents can implement a response with iter_lines() that behave the same as thing but are agentic"""
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
            
            # Check if this is a [DONE] marker
            if chunk.decode('utf-8').strip() == 'data: [DONE]':
                done_marker_seen = True
            
            yield chunk
    
    except Exception as e:
        # Log the error but continue to properly close the stream
        logger.error(f"Error during streaming in stream_generator: {str(e)}")
        
    finally:
        # Send finish_reason "stop" if we haven't seen a finish_reason yet
        # This ensures clients know the response is complete
        finish_chunk = {
            "id": str(uuid.uuid4()),
            "object": "chat.completion.chunk",
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": "stop"
            }]
        }
        yield f'data: {json.dumps(finish_chunk)}\n\n'.encode('utf-8')
        
        # Always send a [DONE] marker at the end if we haven't seen one yet
        # This ensures OpenWebUI knows the stream is complete
        if not done_marker_seen:
            done_marker = 'data: [DONE]\n\n'
            yield done_marker.encode('utf-8')
        
        if audit_callback:
            full_response = "".join(collected_chunks)
            audit_callback(full_response)
               
 
def extract_metadata(request, params=None):
    """
    Extract metadata from request and params.
    
    This function extracts metadata including:
    1. Standard metadata fields from the request's metadata attribute
    2. OpenWebUI-specific metadata like chat_id (at top level or in metadata)
    3. Additional parameters passed in the params dictionary
    
    Args:
        request: The API request object
        params: Optional additional parameters
        
    Returns:
        dict: Combined metadata
    """
    metadata = {}
    chat_id_source = None
    
    # Gather all metadata first, then handle chat_id priority
    
    # Extract from request metadata if available
    if hasattr(request, 'metadata') and request.metadata:
        metadata.update(request.metadata)
    
    # Extract from params if available - highest priority (overrides request metadata)
    if params:
        for key in ['user_id', 'session_id', 'channel_id', 'channel_type', 'api_provider', 'use_sse', 'metadata']:
            if key in params:
                if key == 'metadata' and isinstance(params[key], dict):
                    # For nested metadata in params
                    for param_key, param_value in params[key].items():
                        # Params should override request metadata (highest priority)
                        metadata[param_key] = param_value
                else:
                    # Params override request metadata
                    metadata[key] = params[key]
    
    # Now handle chat_id with explicit priority rules
    
    # 1. Top level chat_id has highest priority
    if hasattr(request, 'chat_id') and request.chat_id:
        metadata['chat_id'] = request.chat_id
        metadata['session_id'] = request.chat_id
        chat_id_source = "top-level"
        logger.info(f"[CHAT DEBUG] Using top-level chat_id {request.chat_id} as session_id")
    
    # 2. Metadata chat_id is next priority
    elif 'chat_id' in metadata and metadata['chat_id']:
        metadata['session_id'] = metadata['chat_id']
        chat_id_source = "metadata"
        logger.info(f"[CHAT DEBUG] Using OpenWebUI metadata.chat_id {metadata['chat_id']} as session_id")
    
    # 3. Params chat_id is lowest priority
    elif params and 'metadata' in params and isinstance(params['metadata'], dict) \
            and 'chat_id' in params['metadata'] and params['metadata']['chat_id']:
        metadata['chat_id'] = params['metadata']['chat_id']
        metadata['session_id'] = params['metadata']['chat_id']
        chat_id_source = "params"
        logger.info(f"[CHAT DEBUG] Using OpenWebUI chat_id {params['metadata']['chat_id']} from params as session_id")
    
    # Generate session_id if not provided by any source
    if 'session_id' not in metadata or not metadata['session_id']:
        metadata['session_id'] = str(uuid.uuid4())
        logger.info(f"[CHAT DEBUG] Generated new session_id: {metadata['session_id']}")
    
    # Log metadata for debugging
    logger.info(f"[CHAT DEBUG] Final extracted metadata with chat_id from {chat_id_source or 'none'}: {metadata}")
    
    return metadata

def audit_request(request:str, 
                  response:str|dict, 
                  metadata:dict=None,
                  user_model = None,
                  max_response_audit_length: int=None):
    """
    Audit the request and response in the database.
    This is a placeholder for the actual implementation.
    
    Mappings of metadata
    the incoming session_id is actually the thread_id
    the session id (id) itself can be generated from a uuid for this chat message
    the user id should be a hash of the incoming string which is possibly an email (userid) is the convention in percolate for users ??
    the query is the request question 
   
    Args:
        request: The original request
        response: The LLM response
        metadata: Additional metadata
    """
 
    if 'transcribed_audio' in metadata:
        """a little janky on the interface but for efficiency we dont want to dump all of this - we could link a raw file later against the id"""
        metadata['query'] = metadata['transcribed_audio'] 
        """before overwriting dump audio record to file storage"""
    
    """we generate a session id if the response did not provided one"""
    session_id = getattr(response, 'session_id', str(uuid.uuid1()))
    
    # Clean metadata - remove empty values and don't store session_id twice
    if metadata:
        # Create a copy of metadata to avoid modifying the original
        session_metadata = {k: v for k, v in metadata.items() if v and k != 'session_id'}
    else:
        session_metadata = {}
    
    try:
        # Create session record with clean metadata
        s = Session(id=session_id, **session_metadata)
        p8.repository(Session).update_records(s)
        logger.info(f"Audited session {session_id} with metadata: {session_metadata}")
        
    except:
        logger.warning("Problem with audit request")
        logger.warning(traceback.format_exc())

    try:
        """Update the user context here - we can also schedule model updates of the user
        -the function will at a minimum merge the latest session's thread into user history
        - we can model the user on a background job occasionally but we can add quick session tags here
        - an example of how this might work our tool use audit observes keys that were used as adds them to popular keys 
        - while we can construct graph paths from the conversation - the process can write discovered graph paths to both session and user model
        """
      
        last_ai_response = str(getattr(response, 'content', ''))
        user_id = metadata.get('userid')
        if user_id:
            p8.repository(User).execute('select * from p8.update_user_model(%s, %s)', data=(user_id, last_ai_response))
            logger.info(f"Updated user model {metadata['userid']}")
        else:
            logger.warning("We do not have a user so we cannot audit.")
        
    except:
        logger.warning("Problem with audit user")
        logger.warning(traceback.format_exc())
         
    try:
        """audit ai responses which is only use in the agentic mode"""
        if hasattr(response, 'ai_responses'):
            p8.repository(AIResponse).update_records(response.ai_responses)
            logger.debug(f"Added AI Response audit")
    except:
        logger.warning("Problem with audit response")
        logger.warning(traceback.format_exc())


         
def try_decode_device_info(di):
    """
    Base64 encoded map is added - try to get it and return as JSON.
    """
    import base64
    import json

    if di:
        try:
            # Base64 decode
            decoded_bytes = base64.b64decode(di)
            # Decode bytes to string (assuming UTF-8)
            decoded_str = decoded_bytes.decode('utf-8')
            # Parse JSON
            return json.loads(decoded_str)
        except Exception:
            # If anything goes wrong, just return the original input
            return {}

    return di

def _ensure_user_hash(userid):
    """
    ths is temporary thing to turn emails into user id for testing
    """
    
    """testing helper for email mapping"""
    if userid and isinstance(userid, str) and "@" in userid:
        return make_uuid( userid.lower() )
    return userid
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
    is_audio: Optional[bool] = Query(False, description="Client asks to decoded base 64 audio using a model"),
    device_info: Optional[str] = Query(None, description="Device info Base64 encoded with arbitrary parameters such as GPS"),
    
    #use_sse: Optional[bool] = Query(False, description="Whether to use Server-Sent Events for streaming"),
    auth_user_id: Optional[str] = Depends(hybrid_auth)
):
    """
    Use any model via an OpenAI API format and get model completions as streaming or non-streaming.
    
    This endpoint can:
    - Accept requests in OpenAI format
    - Call any LLM provider (OpenAI, Anthropic, Google)
    - Stream responses with SSE or standard streaming
    - Provide consistent response format
    """
    
    """TODO we can add basic memory support for completions if enabled but this is a dumb relay and we use the agent/completions for more sophisticated interactions """
    
    # Check for valid authentication - either session or bearer token
    # auth_user_id will be None for bearer token auth, or the user ID for session auth
    
    if device_info:
        device_info = try_decode_device_info(device_info)
        logger.info(f"We have device info {device_info=}")
    else:
        logger.info(f"we did not get any device info")
    
    # Use auth_user_id from HybridAuth if available, otherwise fall back to query param
    effective_user_id = auth_user_id or user_id
    logger.info(f"{effective_user_id}, {session_id}, auth method: {'session' if auth_user_id else 'bearer'}")
    
    try:
        # Collect query parameters into a dict for easier handling
        params = {
            'userid': _ensure_user_hash(effective_user_id),
            'thread_id': session_id,
            'channel_id': channel_id,
            'channel_type': channel_type,
            'api_provider': api_provider,
            'is_audio': is_audio,
            'query': request.compile_question(),
            'agent': request.compile_system(),
            'metadata': device_info
        }
        
        # Remove None values
        params = {k: v for k, v in params.items() if v is not None}
        
        # Determine the dialect based on model or explicit api_provider parameter
        dialect = request.get_dialect(params)
        
        # Determine streaming mode
        stream_mode = request.get_streaming_mode(params)
        
        # Select the appropriate handler based on dialect - we can introduce the percolate proxy here as one way to keep the same endpoint
        if dialect == 'anthropic':
            handler = handle_anthropic_request
        elif dialect == 'google':
            handler = handle_google_request
        else:
            handler = handle_openai_request
        
        # Process the request using the selected handler
        response = handler(request, params)
        
        # Extract metadata for auditing - for now they are as is and we probably will not support them in the request since its better to stick to the openai scheme in the payload - but we can test this in future
        metadata = params# extract_metadata(request, params)
        
        # Handle streaming vs non-streaming responses
        if stream_mode:
            # For streaming responses, use StreamingResponse with appropriate media type
            media_type = "text/event-stream" #if stream_mode == 'sse' else "text/plain"
            
            # Create an audit callback for when streaming completes
            def audit_callback(full_response):
                audit_request(request, full_response, metadata)
                    
            # Create streaming response with all required headers for OpenWebUI compatibility
            streaming_response = StreamingResponse(
                stream_generator(
                    response=response,
                    stream_mode=stream_mode,
                    audit_callback=audit_callback,
                    from_dialect=dialect,  # Pass dialect for canonical format mapping
                    model=request.model  # Pass model name
                ),
                media_type=media_type
            )
            
            # Set essential headers for proper SSE streaming
            # These headers are critical for preventing buffering in proxies and browsers
            streaming_response.headers["Cache-Control"] = "no-cache, no-transform"
            streaming_response.headers["Connection"] = "keep-alive"
            streaming_response.headers["X-Accel-Buffering"] = "no"
            streaming_response.headers["Transfer-Encoding"] = "chunked"
            
            return streaming_response
        else:
            if background_tasks:
                # For non-streaming, add auditing as a background task
                background_tasks.add_task(audit_request, request, response, metadata)
            
            # Add debug logging to trace the response flow
            logger.info(f"Response type in completions: {type(response)}")
            
            # Check if the response has a .json() method (likely an OpenAI or similar response)
            if hasattr(response, 'json') and callable(response.json):
                try:
                    return JSONResponse(content=response.json(), status_code=response.status_code)
                except Exception as e:
                    logger.error(f"Error creating JSON response: {e}")
                    # Handle the case where json() fails
                    from percolate.models import IndexAudit
                    audit_response = IndexAudit(
                        id=str(uuid.uuid1()),
                        model_name=request.model,
                        status="ERROR",
                        message=f"Error processing response: {str(e)}",
                        entity_full_name="ErrorResponse",
                        skipped='p8.AIResponse',
                        tokens=0
                    )
                    return audit_response
            elif hasattr(response, 'model_dump'):
                # It's a Pydantic model, return it directly
                return response
            else:
                # Create a proper response object for validation
                from percolate.models import IndexAudit
                audit_response = IndexAudit(
                    id=str(uuid.uuid1()),
                    model_name=request.model,
                    status="SUCCESS",
                    message="Response processed",
                    entity_full_name="CompletionResponse",
                    skipped='p8.AIResponse',
                    tokens=0
                )
                return audit_response
    except HTTPException:
        
        logger.warning(traceback.format_exc())
        raise
    except:
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=400, detail=f"Something happened that should not have happened.")
    
    
@router.post("/agent/{agent_name}/completions")
async def agent_completions(
    request: CompletionsRequestOpenApiFormat,
    background_tasks: BackgroundTasks,
    user_id: Optional[str] = Query(None, description="ID of the end user making the request"),
    session_id: Optional[str] = Query(None, description="ID for grouping related interactions"),
    channel_id: Optional[str] = Query(None, description="ID of the channel where the interaction happens"),
    channel_type: Optional[str] = Query(None, description="Type of channel (e.g., slack, web, etc.)"),
    api_provider: Optional[str] = Query(None, description="Override the default provider"),
    is_audio: Optional[bool] = Query(False, description="Client asks to decoded base 64 audio using a model"),
    device_info: Optional[str] = Query(None, description="Device info Base64 encoded with arbitrary parameters such as GPS"),
    agent_name: Optional[str] = Path(..., description="Route to a specific agent"),
    #use_sse: Optional[bool] = Query(False, description="Whether to use Server-Sent Events for streaming"),
    auth_user_id: Optional[str] = Depends(hybrid_auth)
):
    """
    Use any model via an OpenAI API format and get model completions as streaming or non-streaming.
    The Agent endpoint specifically allows for you to use your own agent configured in the database on your API.
    Agents have their own crud, search, external functions and of course system prompt
    
    This endpoint can:
    - Accept requests in OpenAI format
    - Call any LLM provider (OpenAI, Anthropic, Google)
    - Stream responses 
    - Provide consistent response format
    """
    
    """
    TODO
        1.  actually load the correct Agent (via `load_model(agent_name)`),
        2.  pass the model name into a real LLM runner (or ModelRunner) instead of `Resources`,
        3.  generate a proper JSON payload when `stream=False`,
        4.  call `stream_generator` with all args or refactor to remove some
    """
    # Check for valid bearer token - this is a temp test key
    
    logger.debug(request)
    
    if device_info:
        device_info = try_decode_device_info(device_info)
        logger.info(f"We have device info {device_info=}")
    else:
        logger.info(f"we did not get any device info")
        
    # Agent name formatting is now handled inside handle_agent_request
    
    logger.info(f"Session for {user_id=}, {session_id=}")
    
    expected_token = "!p3rc0la8!" #<-this a testing thing
    # Use auth_user_id from HybridAuth if available, otherwise fall back to query param
    effective_user_id = auth_user_id or user_id
    logger.info(f"{effective_user_id}, {session_id}, auth method: {'session' if auth_user_id else 'bearer'}")
 
    try:
        # Collect query parameters into a dict for easier handling
        params = {
            'userid': _ensure_user_hash(effective_user_id),
            'thread_id': session_id,
            'channel_id': channel_id,
            'channel_type': channel_type,
            'api_provider': api_provider,
            'is_audio': is_audio,
            'query': request.compile_question(),
            'agent': request.compile_system(),
            'metadata': device_info
        }
        from percolate.models import Resources
        # Remove None values
        params = {k: v for k, v in params.items() if v is not None}
        stream_mode = request.get_streaming_mode(params)
        """wrap the agent call - we can lookup and agent and use the iter lines to get the sse or return the non streaming response"""
        response = handle_agent_request(request, params, request.model, agent_model_name=agent_name)
        
        if background_tasks:
            background_tasks.add_task(audit_request, request, response, params)
                
        if stream_mode:
            # Create streaming response with all required headers for OpenWebUI compatibility
            streaming_response = StreamingResponse(
                stream_generator(
                    response=response, 
                    stream_mode=stream_mode,
                    model=request.model,
                    agent_name=agent_name  # Pass the agent name to display in status messages
                ),
                media_type="text/event-stream"
            )
            
            # Set essential headers for proper SSE streaming
            # These headers are critical for preventing buffering in proxies and browsers
            streaming_response.headers["Cache-Control"] = "no-cache, no-transform"
            streaming_response.headers["Connection"] = "keep-alive"
            streaming_response.headers["X-Accel-Buffering"] = "no"
            streaming_response.headers["Transfer-Encoding"] = "chunked"
            
            return streaming_response
                
        # For non-streaming mode, the handle_agent_request already returns a complete response

        return response
        
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