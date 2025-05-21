from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends
from percolate.models.p8 import Task
from percolate.api.routes.auth import hybrid_auth
import typing
from typing import Optional
from pydantic import BaseModel, Field
from .services import GmailService, EmailMessage
import requests
import percolate as p8
from percolate.models.p8 import TaskResources
import uuid
import html2text

router = APIRouter()

class WebSearch(BaseModel):
    query: str
    
class WebFetch(BaseModel):
    url: str
    html_as_markdown:bool = True
    
class WebSearchResult(BaseModel):
    title: str
    url: str
    summary: str
    content: typing.Optional[str]
    score: float
    #images str
    
class EmailFetch(BaseModel):
    since_iso_date: typing.Optional[str] = Field(None, description="the date since when to get emails")
    limit: typing.Optional[int] = Field(default=5, description="How many emails to check on the client")
    domain_filter:typing.Optional[str] = Field(description="The optional domain filter e.g. get emails from substack.com in the inbox")
    email_address:typing.Optional[str] = Field(None,description="Optional email address - its fine to leave blank if the user has completed an oauth flow which can be assumed")
    task_id: typing.Optional[str|uuid.UUID] = Field(None, description="The task id if known for the session")
class CalFetch(BaseModel):
    query: str

@router.post("/web/search")
async def web_search(
    search_request: WebSearch, 
    background_tasks: BackgroundTasks,
    user_id: Optional[str] = Depends(hybrid_auth)
) -> typing.List[WebSearchResult]:
    """Perform web search"""
    from percolate import PostgresService
    """todo proper parameters and error handling"""
    data  = PostgresService().execute("SELECT * FROM p8.run_web_search(%s)", data=(search_request.query,))
    
    """ingest the resources with content fetch -  think in this case the normal cases is to use the database to do the ingestion always and manage session ids"""
    
    return data
    

@router.post("/web/fetch")
async def fetch_web_resource(
    web_request: WebFetch,
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """
    fetches any file type, typically used for fetching html pages and optionally converting to markdown
    """
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36"
    }
       
    data = requests.get(web_request.url, headers=headers).content.decode()
    if web_request.html_as_markdown:
         return html2text.html2text(data)
    return data

"""the assumption below is that for gsuite the user has completed an external oauth flow"""

@router.post("/mail/fetch")
async def fetch_email(
    email_request: EmailFetch,  
    background_tasks: BackgroundTasks,
    user_id: Optional[str] = Depends(hybrid_auth)
) -> typing.List[dict]:
    """fetch emails for any domain - we use the correct service for the email requested or for the oauth token that is saved.
    for example you can set limit to 5 and filter for the substack.com domain to get newsletters from substack in our inbox
    """
    
    data  = await GmailService().fetch_latest_emails(**email_request.model_dump())
    
    # """save to the repository for ingested resources"""
    # def _ingest(): 
    #     p8.repository(TaskResources).update_records([d.as_task_resource(email_request.task_id) for d in data])
    
    # """we always save these in percolate but we should be able to archive them too"""
    # background_tasks.add_task(_ingest)
    
    return data

@router.post("/calendar/fetch")
async def fetch_calendar(
    calendar_request: CalFetch,
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """fetch calender"""
    pass


#doc fetch - box / gsuite