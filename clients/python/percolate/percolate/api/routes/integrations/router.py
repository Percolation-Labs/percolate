 
from fastapi import APIRouter, HTTPException
from percolate.models.p8 import Task
from percolate.api.routes.auth import get_current_token
import uuid
from fastapi import   Depends
from pydantic import BaseModel

router = APIRouter()

class WebSearch(BaseModel):
    query: str
    
class EmailFetch(BaseModel):
    query: str
    
class CalFetch(BaseModel):
    query: str

@router.post("/web/search")
async def web_search(search_request: WebSearch, user: dict = Depends(get_current_token)):
    pass

@router.get("/mail/fetch")
async def fetch_email(email_request: EmailFetch, user: dict = Depends(get_current_token)):
    pass

@router.get("/calendar/fetch")
async def fetch_calendar(calendar_request: CalFetch, user: dict = Depends(get_current_token)):
    pass


#doc fetch - box / gsuite