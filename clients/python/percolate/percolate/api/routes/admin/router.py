# routers/drafts.py
from fastapi import APIRouter, HTTPException
from fastapi import   Depends, Response 
import json
router = APIRouter()
from percolate.api.auth import get_current_token
from pydantic import BaseModel, Field
import typing

# @router.get("/")
# async def get_x(user: dict = Depends(verify_token)):


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
