# routers/drafts.py
from fastapi import APIRouter, HTTPException, BackgroundTasks
from fastapi import   Depends, Response 
import json
router = APIRouter()
from percolate.api.auth import get_current_token
from pydantic import BaseModel, Field
import typing
import uuid
from percolate.services import PostgresService
from percolate.models.p8 import IndexAudit
from percolate.utils import logger
import traceback

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