# routers/drafts.py
from fastapi import APIRouter, HTTPException, BackgroundTasks
from fastapi import   Depends, Response, Request 
from fastapi.responses import StreamingResponse
import json
import asyncio
router = APIRouter()
from percolate.api.auth import get_current_token
from pydantic import BaseModel, Field
import typing
import uuid
from percolate.services import PostgresService
from percolate.models.p8 import IndexAudit
from percolate.utils import logger
import traceback
from percolate.utils.studio import Project, apply_project
from percolate.services.llm import CallingContext

@router.post("/env/sync")
async def sync_env(user: dict = Depends(get_current_token)):
    """sync env adds whatever keys you have in your environment your database instance
    This is used on database setup or if keys are missing in database sessions
    """
    return Response(content=json.dumps({'status':'ok'}))


class AddApiRequest(BaseModel):
    uri: str = Field(description="Add the uri to the openapi.json for the API you want to add")
    token: typing.Optional[str] = Field(description="Add an optional bearer token or API key for API access")
    verbs: typing.Optional[str] = Field(description="A comma-separated list of verbs e.g. get,post to filter endpoints by when adding endpoints")
    endpoint_filter: typing.Optional[typing.List[str]] = Field(description="A list of endpoints to filter by when adding endpoints")
    
@router.post("/add/api")
async def add_api( request:AddApiRequest,  user: dict = Depends(get_current_token)):
    """add apis to Percolate
    """
    return Response(content=json.dumps({'status':'ok'}))

class AddAgentRequest(BaseModel):
    name: str = Field(description="A unique entity name, fully qualified by namespace or use 'public' as default" )
    functions: dict = Field(description="A mapping of function names in Percolate with a description of how the function is useful to you")
    spec: dict = Field(description="The Json spec of your agents structured response e.g. from a Pydantic model")
    description: str = Field(description="Your agent description - acts as a system prompt")
    
    
@router.post("/add/agent")
async def add_api( request:AddAgentRequest,  user: dict = Depends(get_current_token)):
    """add agents to Percolate. Agents require a Json Schema for any structured response you want to use, a system prompt and a dict/mapping of external registered functions.
    Functions can be registered via the add APIs endpoint.
    """
    return Response(content=json.dumps({'status':'ok'}))

@router.post("/add/project")
async def add_project( project: Project,  user: dict = Depends(get_current_token)):
    """Post the project yaml/json file to apply the settings. This can be used to add apis, agents and models. 
    
    - If you have set environment keys in your API we will sync these to your database if the `sync-env` flag is set in the project options
    - If you want to index the Percolation documentation set the flag `index-docs`
    """
    results = apply_project(project)
    return Response(content=json.dumps(results))


@router.get("/slow-endpoint")
async def slow_response():
    import time
    time.sleep(10)  # Simulate a delay
    return {"message": "This response was delayed by 10 seconds"}


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
    import time
    import json
    
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
    import time
    from percolate.models import MessageStack
    from percolate.services.llm import LanguageModel
    
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


class IndexRequest(BaseModel):
    """a request to update the indexes for entities by full name"""
    entity_full_name: str = Field(description="The full entity name - optionally omit for public namespace")

 
@router.post("/index/", response_model=IndexAudit)
async def index_entity(request: IndexRequest, background_tasks: BackgroundTasks, user: dict = Depends(get_current_token))->IndexAudit:
    """index entity and get an audit log id to check status
    the index is created as a background tasks and we respond with an id ref that can be used in the get/
    """
    id=uuid.uuid1()
    s = PostgresService(IndexAudit)
    try:
        
        record = IndexAudit(id=id, model_name='percolate', entity_full_name=request.entity_full_name, metrics={}, status="REQUESTED", message="Indexed requested")
        s.update_records(record)
        """todo create an audit record pending and use that in the api response"""
        background_tasks.add_task(s.index_entity_by_name, request.entity_full_name, id=id)
        return record
    except Exception as e:
        """handle api errors"""
        logger.warning(f"/admin/index {traceback.format_exc()}")
        record = IndexAudit(id=id,model_name='percolate',entity_full_name=request.entity_full_name, metrics={}, status="ERROR", message=str(e))
        """log the error"""
        s.update_records(record)
        raise HTTPException(status_code=500, detail="Failed to manage the index")
    
@router.get("/index/{id}", response_model=IndexAudit)
async def get_index(id: uuid.UUID) -> IndexAudit:
    """
    request the status of the index by id
    """
    #todo - proper error handling
    records =  PostgresService.get_by_id(id)
    if records:
        return records[0]
    """TODO error not found"""
    return {}