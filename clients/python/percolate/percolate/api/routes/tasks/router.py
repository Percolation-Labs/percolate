 
from fastapi import APIRouter, HTTPException
from percolate.models.p8 import Task
from percolate.api.auth import get_current_token
import uuid
from fastapi import   Depends
 
router = APIRouter()

@router.get("/")
async def get_tasks(user: dict = Depends(get_current_token)):
    pass

@router.post("/")
async def create_task(task: Task):
    pass

@router.get("/{task_name}")
async def get_task_by_name(draft_id: int):
    pass

@router.put("/{task_name}")
async def update_task(task_name: str, task: Task):
    pass

@router.delete("/{task_id}")
async def delete_task(draft_id: uuid.UUID):
    pass
