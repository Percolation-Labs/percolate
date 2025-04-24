 
from fastapi import APIRouter, HTTPException, Query, Path, Response,BackgroundTasks
from percolate.models.p8 import Task,ResearchIteration
import percolate as p8
from percolate.api.routes.auth import get_current_token
import uuid
from fastapi import   Depends
import typing
from pydantic import BaseModel
from percolate.utils import logger

router = APIRouter()

@router.get("/")
async def get_tasks(user: dict = Depends(get_current_token))->typing.List[Task]:
    return Response('Dummy response')

class TaskSearch(BaseModel):
    query: str

@router.post("/search", response_model=typing.List[Task])
async def search_task(search: TaskSearch, user: dict = Depends(get_current_token)) -> typing.List[Task]:
    """semantic task search"""
    result = p8.repository(Task).search(search.query)
    
    """the semantic result is the one we want here"""
    if result and result[0].get('vector_result'):
        return result[0]['vector_result']
    
    """todo error handling"""
    
@router.post("/", response_model=Task)
async def create_task(task: Task, user: dict = Depends(get_current_token)) -> Task:
    """create a task"""
    results = p8.repository(Task).update_records(task)
    if results:
        return results[0]
    raise Exception("this should not happened but we will be adding error stuff")

@router.get("/{task_name}/comments")
async def get_task_comments_by_name(
    task_name: str = Path(..., description="The unique name of the task"),
    user: dict = Depends(get_current_token)
) -> typing.List[dict]:
    """Fetch the comments related to this task if you know its entity name"""
    return [{
        'user': 'dummy_user',
        'comment': 'dummy_comment'
    },{
        'user': 'dummy_user',
        'comment': 'dummy_comment'
    }]

@router.get("/{task_name}", response_model=Task)
async def get_task_by_name(
    task_name: str = Path(..., description="The unique name of the task"),
    user: dict = Depends(get_current_token)
) -> Task:
    """Retrieve a task by name"""
    return {}

@router.post("/research", response_model=ResearchIteration)
async def create_research_iteration(
    task: ResearchIteration,
    user: dict = Depends(get_current_token)
) -> ResearchIteration:
    """create a research plan - conceptual diagram and question set"""
    results = p8.repository(ResearchIteration).update_records(task)
    if results:
        return results[0]
    raise Exception("this should not happened but we will be adding error stuff")

def exec_research_tasks(task):
    repo = p8.repository(ResearchIteration)
    """this can be parallel in future but now our free tier is one request per second anyway"""
    for q in task.question_set:
        """this guy does a lot
        - first we do the web search and fetch the content optionally 
        - we insert the results into task/resources
        - we build the index - a smart index can also fetch content when the first step does not
        - the index is a Percolate special that adds vector and graph index for parsed content
        """
        repo.execute(f"SELECT * FROM p8.insert_web_search_results(%s,%s)", data=(q.query,task.task_id))
        
    return {}
            
@router.post("/research/execute", response_model=ResearchIteration)
async def execute_research_iteration(
    task: ResearchIteration,
    user: dict = Depends(get_current_token)
) -> ResearchIteration:
    """execute a research plan - perform each search in the question set - this can take time so should be done as background tasks"""
    
    logger.debug(task)
    
    result = exec_research_tasks(task)
    
    """handle errors and/or update the task response"""
    return task

@router.post("/research/queue", response_model=ResearchIteration)
async def queue_research_iteration(
    task: ResearchIteration, 
    background_tasks: BackgroundTasks,
    user: dict = Depends(get_current_token)
) -> ResearchIteration:
    """execute a research plan - perform each search in the question set - this can take time so should be done as background tasks"""
    
    result = background_tasks(exec_research_tasks, task)
    
    """handle errors and/or update the task response to say we have changed its status to queue"""
    
    return task
        
    



# @router.put("/{task_name}")
# async def update_task(task_name: str, task: Task):
#     pass

# @router.delete("/{task_id}")
# async def delete_task(draft_id: uuid.UUID):
#     pass
