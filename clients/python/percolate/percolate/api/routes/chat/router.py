from fastapi import APIRouter, HTTPException, Depends, Request
from fastapi.responses import StreamingResponse
import json
import asyncio
import time
import uuid
import traceback
import typing
from pydantic import BaseModel, Field
from percolate.api.auth import get_current_token
from percolate.utils import logger
from percolate.models import MessageStack
from percolate.services.llm import CallingContext, LanguageModel

router = APIRouter()

class CompletionsRequest(BaseModel):
    """OpenAI-compatible chat completions request"""
    model: str = Field(description="The model to use for completion")
    messages: typing.List[dict] = Field(description="The messages to generate from", min_items=1)
    tools: typing.Optional[typing.List[dict]] = Field(default=None, description="Function calling tools")
    temperature: typing.Optional[float] = Field(default=0.7, description="Sampling temperature")
    stream: typing.Optional[bool] = Field(default=False, description="Whether to stream the response")
    max_tokens: typing.Optional[int] = Field(default=None, description="Maximum tokens to generate")
    
class CompletionsChoice(BaseModel):
    """A single completion choice"""
    index: int = 0
    message: dict
    finish_reason: str = "stop"
    
class CompletionsUsage(BaseModel):
    """Token usage information"""
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    
class CompletionsResponse(BaseModel):
    """OpenAI-compatible chat completions response"""
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: typing.List[CompletionsChoice]
    usage: CompletionsUsage

async def convert_anthropic_to_openai_streaming(response, model_name):
    """
    Convert Anthropic streaming response to OpenAI format for streaming
    
    Args:
        response: The streaming response from Anthropic
        model_name: The model name to use in the response
    """
    import time
    
    request_id = str(uuid.uuid4())
    timestamp = int(time.time())
    content_text = ""
    
    # Initial message with role
    data = {
        "id": request_id,
        "object": "chat.completion.chunk",
        "created": timestamp,
        "model": model_name,
        "choices": [
            {
                "index": 0,
                "delta": {
                    "role": "assistant"
                },
                "finish_reason": None
            }
        ]
    }
    yield f"data: {json.dumps(data)}\n\n"
    
    # Process the Anthropic response
    event_type = None
    content_block_type = None
    
    for line in response.iter_lines():
        if not line:
            continue
            
        decoded_line = line.decode("utf-8")
        
        # Handle event type lines
        if decoded_line.startswith('event:'):
            event_type = decoded_line.replace("event: ", "").strip()
            continue
        else:
            # Remove the "data: " prefix
            decoded_line = decoded_line.replace("data: ", "").strip()
        
        if decoded_line and decoded_line != "[DONE]":
            try:
                json_data = json.loads(decoded_line)
                event_type = json_data.get("type")
                
                # Handle different event types from Anthropic stream
                if event_type == "content_block_delta":
                    content_type = json_data["delta"].get("type")
                    if content_type == "text_delta":
                        text = json_data["delta"].get("text", "")
                        if text:
                            # Send this text chunk in OpenAI format
                            data = {
                                "id": request_id,
                                "object": "chat.completion.chunk",
                                "created": timestamp,
                                "model": model_name,
                                "choices": [
                                    {
                                        "index": 0,
                                        "delta": {
                                            "content": text
                                        },
                                        "finish_reason": None
                                    }
                                ]
                            }
                            yield f"data: {json.dumps(data)}\n\n"
                            await asyncio.sleep(0.01)  # Small delay to ensure client receives chunks
                
                # Detect when the message is complete
                elif event_type == "message_delta" and json_data.get("stop_reason"):
                    # Final message with finish reason
                    data = {
                        "id": request_id,
                        "object": "chat.completion.chunk",
                        "created": timestamp,
                        "model": model_name,
                        "choices": [
                            {
                                "index": 0,
                                "delta": {},
                                "finish_reason": "stop"
                            }
                        ]
                    }
                    yield f"data: {json.dumps(data)}\n\n"
                
            except json.JSONDecodeError:
                pass  # Handle incomplete JSON chunks
    
    # Final [DONE] message
    yield "data: [DONE]\n\n"

def convert_anthropic_to_openai_response(response, model_name):
    """
    Convert a complete Anthropic response to OpenAI format
    
    Args:
        response: The complete response from Anthropic API
        model_name: The model name to use in the response
    """
    anthropic_data = response.json()
    
    # Extract text content from Anthropic response
    text_content = ""
    for block in anthropic_data.get("content", []):
        if block.get("type") == "text":
            text_content += block.get("text", "")
    
    # Build OpenAI format response
    return {
        "id": str(uuid.uuid4()),
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model_name,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": text_content
                },
                "finish_reason": "stop"
            }
        ],
        "usage": {
            "prompt_tokens": anthropic_data.get("usage", {}).get("input_tokens", 0),
            "completion_tokens": anthropic_data.get("usage", {}).get("output_tokens", 0),
            "total_tokens": (
                anthropic_data.get("usage", {}).get("input_tokens", 0) + 
                anthropic_data.get("usage", {}).get("output_tokens", 0)
            )
        }
    }

async def call_anthropic_api(messages, stream=False, max_tokens=1000, temperature=0.7):
    """
    Call the Anthropic API directly 
    
    Args:
        messages: The messages to send to Anthropic
        stream: Whether to stream the response
        max_tokens: Maximum tokens to generate
        temperature: Temperature for response generation
    """
    import requests
    import os
    
    # Format messages for Anthropic
    anthropic_messages = []
    system_content = None
    
    for msg in messages:
        if msg["role"] == "system":
            system_content = msg["content"]
        else:
            anthropic_messages.append({
                "role": msg["role"],
                "content": msg["content"]
            })
    
    # Prepare the request
    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": os.environ.get("ANTHROPIC_API_KEY"),
        "anthropic-version": "2023-06-01"
    }
    
    data = {
        "model": "claude-3-haiku-20240307",  # Using a reliable Claude model
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": anthropic_messages,
        "stream": stream
    }
    
    if system_content:
        data["system"] = system_content
    
    # Make the API call
    return requests.post(url, headers=headers, json=data, stream=stream)

@router.post("/completions")
async def chat_completions(request: CompletionsRequest, user: dict = Depends(get_current_token)):
    """
    OpenAI-compatible chat completions endpoint that can produce streaming or non-streaming responses.
    This endpoint calls the Anthropic API and transforms the response to OpenAI format.
    
    - Supports both streaming and non-streaming responses
    - Compatible with OpenAI client libraries
    - Demonstrates converting from Anthropic API format to OpenAI format
    
    Example usage:
    ```
    curl -X POST http://localhost:5000/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer YOUR_TOKEN" \
      -d '{
        "model": "claude-model",
        "messages": [{"role": "user", "content": "Tell me a joke about programming"}],
        "stream": true,
        "temperature": 0.7
      }'
    ```
    """
    try:
        # Check for ANTHROPIC_API_KEY
        import os
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            # Fall back to simulated response if no API key is available
            simulated_response = f"This is a simulated response because no ANTHROPIC_API_KEY was found in environment variables."
            logger.warning("No ANTHROPIC_API_KEY found, using simulated response")
            
            if request.stream:
                # Simulate streaming
                return StreamingResponse(
                    _simulated_stream_generator(simulated_response, model=request.model), 
                    media_type="text/event-stream"
                )
            else:
                # Simulate standard response
                return _build_simulated_response(simulated_response, request)
        
        # Call Anthropic API
        response = await call_anthropic_api(
            messages=request.messages,
            stream=request.stream,
            max_tokens=request.max_tokens or 1000,
            temperature=request.temperature
        )
        
        # Check for API error
        if response.status_code != 200:
            error_msg = f"Anthropic API error: {response.status_code} - {response.text}"
            logger.error(error_msg)
            raise HTTPException(status_code=response.status_code, detail=error_msg)
        
        # Process response based on streaming or non-streaming
        if request.stream:
            # Return a streaming response in OpenAI format, converted from Anthropic format
            return StreamingResponse(
                convert_anthropic_to_openai_streaming(response, request.model), 
                media_type="text/event-stream"
            )
        else:
            # Return a non-streaming response in OpenAI format
            openai_format = convert_anthropic_to_openai_response(response, request.model)
            return CompletionsResponse(**openai_format)
            
    except Exception as e:
        logger.error(f"Error in chat completions: {str(e)}")
        logger.error(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"Error processing completions request: {str(e)}")

async def _simulated_stream_generator(content, model="gpt-4", delay=0.05):
    """Generate a simulated streaming response for testing"""
    request_id = str(uuid.uuid4())
    timestamp = int(time.time())
    
    # Initial message with role
    data = {
        "id": request_id,
        "object": "chat.completion.chunk",
        "created": timestamp,
        "model": model,
        "choices": [
            {
                "index": 0,
                "delta": {
                    "role": "assistant"
                },
                "finish_reason": None
            }
        ]
    }
    yield f"data: {json.dumps(data)}\n\n"
    
    # Stream content in small chunks
    words = content.split()
    chunk_size = 2  # Words per chunk
    chunks = [' '.join(words[i:i+chunk_size]) for i in range(0, len(words), chunk_size)]
    
    for chunk in chunks:
        await asyncio.sleep(delay)
        data = {
            "id": request_id,
            "object": "chat.completion.chunk",
            "created": timestamp,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "delta": {
                        "content": chunk + " "
                    },
                    "finish_reason": None
                }
            ]
        }
        yield f"data: {json.dumps(data)}\n\n"
    
    # Final message
    await asyncio.sleep(delay)
    data = {
        "id": request_id,
        "object": "chat.completion.chunk",
        "created": timestamp,
        "model": model,
        "choices": [
            {
                "index": 0,
                "delta": {},
                "finish_reason": "stop"
            }
        ]
    }
    yield f"data: {json.dumps(data)}\n\n"
    yield "data: [DONE]\n\n"

def _build_simulated_response(content, request):
    """Build a simulated non-streaming response"""
    token_count = len(content.split())
    prompt_tokens = len(" ".join(m.get("content", "") for m in request.messages).split())
    
    return CompletionsResponse(
        id=str(uuid.uuid4()),
        created=int(time.time()),
        model=request.model,
        choices=[
            CompletionsChoice(
                message={
                    "role": "assistant",
                    "content": content
                },
                finish_reason="stop"
            )
        ],
        usage=CompletionsUsage(
            prompt_tokens=prompt_tokens,
            completion_tokens=token_count,
            total_tokens=prompt_tokens + token_count
        )
    )