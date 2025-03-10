 
from fastapi import APIRouter, HTTPException, BackgroundTasks
from percolate.models.p8 import Task
from percolate.api.routes.auth import get_current_token
import typing
from fastapi import   Depends
from pydantic import BaseModel
from .services import GmailService, EmailMessage
import requests
import percolate as p8

router = APIRouter()

class WebSearch(BaseModel):
    query: str
    
class WebSearchResult(BaseModel):
    title: str
    url: str
    summary: str
    content: typing.Optional[str]
    score: float
    #images str
    
class EmailFetch(BaseModel):
    since: typing.Optional[str] = None
    to: typing.Optional[str] = None
    domain_filter:typing.Optional[str] = None
    email_address:typing.Optional[str] = None
    
class CalFetch(BaseModel):
    query: str

@router.post("/web/search")
async def web_search(search_request: WebSearch, background_tasks: BackgroundTasks, user: dict = Depends(get_current_token))->typing.List[WebSearchResult]:
    """Perform web search"""
    from percolate import PostgresService
    """todo proper parameters and error handling"""
    data  = PostgresService().execute("SELECT * FROM p8.run_web_search(%)", data=(search_request.query,))
    
    """ingest the resources with content fetch -  think in this case the normal cases is to use the database to do the ingestion always and manage session ids"""
    
    return data
    

@router.get("/web/fetch")
async def fetch_web_resource(url:str, html_as_markdown:bool = True):
    """
    fetches any file type, typically used for fetching html pages and optionally converting to markdown
    """
    data = requests.get(url).content
    if html_as_markdown:
        pass
    return data

@router.get("/mail/fetch")
async def fetch_email(email_request: EmailFetch,  background_tasks: BackgroundTasks, user: dict = Depends(get_current_token),)->typing.List[EmailMessage]:
    """fetch emails for any domain - we use the correct service for the email requested or for the oauth token that is saved"""
    
    data  = GmailService.fetch_email(**email_request.model_dump())
    
    """save to the repository for ingested resources"""
    def _ingest(): 
        p8.repository(IngestedResource).update_records([d.as_resource() for d in data])
    
    """we always save these in percolate but we should be able to archive them too"""
    background_tasks.add_task(_ingest)
    
    return data

@router.get("/calendar/fetch")
async def fetch_calendar(calendar_request: CalFetch, user: dict = Depends(get_current_token)):
    """fetch calender"""
    pass


#doc fetch - box / gsuite