 
from fastapi import APIRouter, HTTPException
from percolate.models.p8 import Task
from percolate.api.routes.auth import get_current_token
import uuid
from fastapi import   Depends
from pydantic import BaseModel

router = APIRouter()

class CompletionsRequest(BaseModel):
    """the OpenAPI scheme completions wrapper for Percolate"""
    model:str
    #TODO
    
@router.post("/completions")
async def completions(request: CompletionsRequest, user: dict = Depends(get_current_token)):
    """Use any model and get model completions as streaming or non streaming with SSE option"""
    pass

class SimpleAskRequest(BaseModel):
    """the OpenAPI scheme completions wrapper for Percolate"""
    model:str
    question:str
    agent: str
    #TODO
    
@router.post("/")
async def ask(request: SimpleAskRequest, user: dict = Depends(get_current_token)):
    """A simple ask request using any percolate agent and model"""
    pass

 