 
from fastapi import APIRouter, HTTPException, Query, Path, Response
from percolate.models.p8 import Task
import percolate as p8
from percolate.api.routes.auth import get_current_token
import uuid
from fastapi import   Depends
import typing
from pydantic import BaseModel

router = APIRouter()

@router.get("/")
async def get_tasks(user: dict = Depends(get_current_token))->typing.List[Task]:
    return Response('Dummy response')

class TaskSearch(BaseModel):
    query: str

@router.post("/search", response_model=typing.List[Task])
async def search_task(search:TaskSearch)->typing.List[Task]:
    """semantic task search"""
    result =  p8.repository(Task).search(search.query)
    
    """the semantic result is the one we want here"""
    if result and result[0].get('vector_result'):
        return result[0]['vector_result']
    
    """todo error handling"""
    
@router.post("/", response_model=Task)
async def create_task(task: Task)->Task:
    """create a task"""
    results =  p8.repository(Task).update_records(task)
    if results:
        return results[0]
    raise Exception("this should not happened but we will be adding error stuff")

@router.get("/{task_name}/comments")
async def get_task_comments_by_name(task_name: str = Path(..., description="The unique name of the task"))->typing.List[dict]:
    """Fetch the comments related to this task if you know its entity name"""
    return [{
        'user': 'dummy_user',
        'comment': 'dummy_comment'
    },{
        'user': 'dummy_user',
        'comment': 'dummy_comment'
    }]

@router.get("/{task_name}",response_model=Task)
async def get_task_by_name(task_name: str = Path(..., description="The unique name of the task"))->Task:
    """Retrieve a task by name"""
    return {}



# @router.put("/{task_name}")
# async def update_task(task_name: str, task: Task):
#     pass

# @router.delete("/{task_id}")
# async def delete_task(draft_id: uuid.UUID):
#     pass
