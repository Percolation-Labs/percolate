 
from fastapi import APIRouter, HTTPException
from percolate.models.p8 import Task
from percolate.api.auth import get_current_token
import uuid
from fastapi import   Depends
from pydantic import BaseModel

router = APIRouter()

class CompletionsRequest(BaseModel):
    """the OpenAPI scheme completions wrapper for Percolate"""
    model:str
    #TODO
    
@router.post("/completions")
async def get_tasks(request: CompletionsRequest, user: dict = Depends(get_current_token)):
    pass

class SimpleAskRequest(BaseModel):
    """the OpenAPI scheme completions wrapper for Percolate"""
    model:str
    question:str
    agent: str
    #TODO
    
@router.post("/")
async def ask_simple(request: SimpleAskRequest, user: dict = Depends(get_current_token)):
    pass

 