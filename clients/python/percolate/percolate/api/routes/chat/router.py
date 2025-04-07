 
from fastapi import APIRouter, HTTPException
from percolate.models.p8 import Task
from percolate.api.routes.auth import get_current_token
import uuid
from fastapi import   Depends
from fastapi.responses import StreamingResponse, JSONResponse
from .models import *
import asyncio
import percolate as p8
from percolate.services import ModelRunner

router = APIRouter()
   
    
async def stream_generator(response,stream_mode,finally_callback):
    collected_chunks = []
    try:
        # Simulate a stream of data (could be from an external API, etc.)
        for i in range(10):
            # For SSE, you might format your message as:
            # chunk = f"data: chunk {i}\n\n"
            chunk = f"chunk {i}\n"  
            collected_chunks.append(chunk)
            yield chunk  # send chunk to the client
            await asyncio.sleep(1)  # simulate delay between chunks
    finally:
        # When the generator is exhausted or the client disconnects,
        # run the closure process on the collected data.
        full_response = "".join(collected_chunks)
        if finally_callback:
            finally_callback(full_response)

@router.post("/completions")
async def completions(request: CompletionsRequestOpenApiFormat, params:dict=None, user: dict = Depends(get_current_token)):
    """Use any model via an OpenAPI api format and get model completions as streaming or non streaming (with SSE option)"""
    
    """determine the dialect first"""
    dialect = request.get_dialect(params)
    """determine streaming or not | see or not"""
    stream_mode = request.get_streaming_mode(params) # returns None, SSE, standard
    
    """processes the response for the given dialect and map it to the canonical form"""
    handler = handle_request
    if dialect == 'anthropic':
        handler =  handle_anthropic_request
    elif dialect == 'google':
        handler =  handle_google_request 
        
    response = handler(request, params)

    media_type = "text/plain" if stream_mode != 'sse' else 'text/event-stream'
    
    """prepare the finally callback with params"""
    if not stream_mode:
        """run audits here in a background process"""
        
        return JSONResponse(content=response, status_code=201)
    """the generator has a finally block that runs the audit"""
    return StreamingResponse(stream_generator(response,stream_mode,finally_callback=None), media_type=media_type) 


@router.post("/agent/{agent}/completions")
async def agent_completions(request: CompletionsRequestOpenApiFormat, params:dict=None, agent:str=None,  user: dict = Depends(get_current_token)):
    """Use any model and get model completions as streaming or non streaming with SSE option 
    - if the agent is used, then we are processing server side - if we dont use streaming we return a callback id that can be polled but streaming is recommended for this mode"""
    
    """determine the dialect first"""
    
    """run the model in Percolate"""
    id = None
    return id

@router.post("/agent/{agent}/poll-completions")
async def agent_completions_ull(id:str, params:dict=None, agent:str=None, user: dict = Depends(get_current_token)):
    """Paired with agent completions this is used to poll sessions that are processed in the background"""
    
    """determine the dialect first"""
    
    return
    
class SimpleAskRequest(BaseModel):
    """the OpenAPI scheme completions wrapper for Percolate"""
    model:str = Field(None, description="The language model to use - Percolate defaults to GPT models")
    question:str = Field(None, description= "A simple question to ask")
    agent: str = Field(None, description="The configured agent - the Percolate agent will be used by default to answer generic questions")
    max_iteration: int = Field(3, description="The agent runs loops - for simple ask fewer is better")
    #TODO
    
@router.post("/")
async def ask(request: SimpleAskRequest, user: dict = Depends(get_current_token)):
    """A simple ask request using any percolate agent and language model.
    Remember you can configure the agents to use tools a priori
    """
    from percolate.services import ModelRunner
    agent = p8.Agent(p8.load_model(request.agent))
    return JSONResponse(content=agent.run(request.question, language_model=request.model ))
    


 