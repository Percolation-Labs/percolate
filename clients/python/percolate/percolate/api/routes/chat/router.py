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

async def stream_generator(content, delay=0.05, model="gpt-4", req_id=None):
    """Generate a streaming response with artificial chunks for testing
    
    Args:
        content: The content to stream
        delay: Delay between chunks to simulate network latency
        model: Model name to include in the response
        req_id: Request ID to use across all chunks (creates one if not provided)
    """
    # Use a consistent ID across all chunks
    request_id = req_id or str(uuid.uuid4())
    timestamp = int(time.time())
    
    # Initial response data with the role
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
    
    for i, chunk in enumerate(chunks):
        await asyncio.sleep(delay)  # Simulate network delay
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
    
    # Final done message
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

async def stream_custom_with_callback(callback, content, model="gpt-4"):
    """
    This is a placeholder for a future implementation where we would use a callback 
    to stream responses directly from the LLM service through our endpoint.
    
    In the future, this would be used to adapt the streaming format from various LLM providers
    to the OpenAI format. Currently, it's just a placeholder function.
    """
    # In a real implementation, this would be used as the callback for streaming responses
    # and would convert the response to the OpenAI format
    pass

@router.post("/completions")
async def chat_completions(request: CompletionsRequest, user: dict = Depends(get_current_token)):
    """
    OpenAI-compatible chat completions endpoint that can produce streaming or non-streaming responses.
    This endpoint proxies to other LLM services and returns responses in OpenAI format.
    
    - Supports both streaming and non-streaming responses
    - Compatible with OpenAI client libraries
    - Can be extended to support Anthropic and Google formats in the future
    """
    try:
        # In a production implementation, we would use LanguageModel to handle the actual API call
        # For now, we'll simulate responses for both streaming and non-streaming cases
        
        # Convert the request messages to a format percolate understands
        # Extract system prompt if present
        system_prompt = next((m.get("content", "") for m in request.messages if m.get("role") == "system"), None)
        
        # Get the last user message
        last_message = next((m for m in reversed(request.messages) if m.get("role") == "user"), None)
        last_content = last_message.get("content", "") if last_message else ""
        
        # For demo purposes, generate a response. In production this would use the real model:
        # message_stack = MessageStack(last_content, system_prompt=system_prompt)
        # context = CallingContext(prefers_streaming=request.stream, model=request.model, temperature=request.temperature)
        # if request.stream:
        #     context.streaming_callback = custom_streaming_callback
        # model = LanguageModel(request.model)
        # response = model(message_stack, functions=request.tools, context=context)
        
        # For testing purposes, generate a simulated response
        response_content = f"This is a simulated response to: {last_content}"
        
        if request.stream:
            # Return a streaming response in OpenAI format
            return StreamingResponse(
                stream_generator(
                    content=response_content,
                    model=request.model,
                    delay=0.05  # Configurable delay for testing
                ), 
                media_type="text/event-stream"
            )
        else:
            # Return a non-streaming response in OpenAI format
            return CompletionsResponse(
                id=str(uuid.uuid4()),
                created=int(time.time()),
                model=request.model,
                choices=[
                    CompletionsChoice(
                        message={
                            "role": "assistant",
                            "content": response_content
                        },
                        finish_reason="stop"
                    )
                ],
                usage=CompletionsUsage(
                    prompt_tokens=len(" ".join(m.get("content", "") for m in request.messages).split()),
                    completion_tokens=len(response_content.split()),
                    total_tokens=len(" ".join(m.get("content", "") for m in request.messages).split()) + 
                                len(response_content.split())
                )
            )
    except Exception as e:
        logger.error(f"Error in chat completions: {str(e)}")
        logger.error(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"Error processing completions request: {str(e)}")