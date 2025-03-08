 
from fastapi import APIRouter, HTTPException, Query, Path, Response
from percolate.models.p8 import Task
from percolate.api.routes.auth import get_current_token
import uuid
from fastapi import   Depends
import typing

router = APIRouter()

@router.get("/")
async def get_tasks(user: dict = Depends(get_current_token))->typing.List[Task]:
    return Response('Dummy response')

@router.post("/", response_model=Task)
async def create_task(task: Task)->Task:
    return task

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
