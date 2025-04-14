from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends
from percolate.api.routes.auth import get_current_token
from pydantic import BaseModel, Field
from percolate.services import PostgresService
import typing
from percolate.models.p8 import Function,ApiProxy

import typing
import percolate as p8
from percolate.api.routes.auth import get_current_token 
 
router = APIRouter(dependencies=[Depends(get_current_token)])

class ToolSearch(BaseModel):
    query: str
    
class FunctionCall(BaseModel):
    name: str
    arguments: dict
    
@router.post("/eval", response_model=typing.List[dict])
def eval_tool(function_call: FunctionCall):
    return PostgresService().eval_function_call(function_call.name, function_call.arguments)

@router.get("/", response_model=typing.List[dict])
def list_tools(scheme:str=None, names:str=None):
    """List tools - currently just some test tools"""
    
    """this is currently for testing only"""
    
    names = ['search', 'get_entities', 'get_pet_findByStatus']
    return PostgresService().get_tools_metadata(scheme=scheme, names = names)


@router.get("/api-proxy", response_model=typing.List[ApiProxy])
def list_apis():
    return []



@router.get("/{tool_name}", response_model=Function)
def get_tool(tool_name: str):
    fn = None
    if not FileNotFoundError:
        raise HTTPException(status_code=404, detail="Tool not found")
    return fn


#we can leave this as admin endpoints probably
# @router.put("/{tool_name}", response_model=Function)
# def update_tool(tool_name: str, tool: Function):
 
#     return {}

# @router.delete("/{tool_name}")
# def delete_tool(tool_name: str): 
#     return {"message": f"Tool '{tool_name}' deleted successfully"}
 
# @router.put("/api-proxy/{api_name}", response_model=ApiProxy)
# def update_api(api_name: str, api: ApiProxy):

#     return {}

# @router.post("/", response_model=Function)
# def create_tool(tool: Function):
#     return tool

# @router.post("/api-proxy", response_model=ApiProxy)
# def create_api(api: ApiProxy):
#     return api


@router.post("/search")
def tool_search(search: ToolSearch):
    """semantic/search for tools"""
    result =  p8.repository(Function).search(search.query)
    
    """the semantic result is the one we want here"""
    if result and result[0].get('vector_result'):
        return result[0]['vector_result']
    
 