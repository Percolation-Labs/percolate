

from mcp.server.fastmcp import FastMCP
import requests
import typing
from pydantic import BaseModel
import datetime

mcp = FastMCP("percolate")

"""the static mcp server is a percolate binding for
- asking the percolate agent anything
- ingesting emails filtered by domains e.g. substack 
- adding documents
- searching the web
- ingesting web targets
- adding/updating tasks

when the Percolate API is running e.g. on Docker or on some remote, the MCP server can bind to it

mcp install static_server.py
mcp dev static_server.py

"""

#parameter can change this
PERCOLATE_HOST = f"http://localhost:5000"

class SearchResult(BaseModel):
    url:str
    content:str
    summary:str

class Task(BaseModel):
    name:str
    description:str
    labels: typing.List[str] = []
    due_date:datetime.datetime = None
    
def run_auth_flow():
    """triggers an auth flow for user X to log in and those are the emails we fetch with the given provider
    """
    pass

@mcp.tool()
def ask_percolate(query:str) -> str:
    """ask anything of the percolate agent"""
    return "TEST"

@mcp.tool()
def get_entities(keys: typing.List[str]) -> str:
    """supply one or more entity keys to get details about them. 
    entities can be tasks by name, resources by uri or any other entity encountered in the session and stored in Percolate.
    this is a generic function to lookup any such named resource.
    """
    return "TEST"

@mcp.tool()
def web_search(query:str) -> typing.List[SearchResult]:
    """query the web with a search query and receive a list of summarized results"""
    
    url = f"{PERCOLATE_HOST}/x/web/search"
    
    response = requests.post(url, data={
        'query': query
    })
    
    """checks TODO"""
    
    return [SearchResult(**d) for d in response.json()]

 
@mcp.tool()
def fetch_recent_email(limit:int=5,filter_domain:str=None) -> typing.List[SearchResult]:
    """fetch recent emails for the user limited by parameter default to 5. Optionally filter emails from a domain
    """
    
    run_auth_flow()
    
    url = f"{PERCOLATE_HOST}/x/mail/fetch"
    
    """todo query pass through - we are just testing for now"""
    response = requests.post(url, data={ })
    
    """checks TODO - error handling"""
    
    return [d for d in response.json()]
    
 

#we could also run integrations e.g. sync box files and that sort of thing here - list supported integrations and then use some watermark based sync - really percolate should already have tasks for this
#draft email/send email in future but as we are in research agent mode this is a nice to have - other things like calendar could be done

@mcp.tool()
def ingest_resource(uri:str, comment:str=None, return_content:bool=False) -> str:
    """add a resource such as website or file with an optional comment.
    This can be used to make extra content available to the session and you can ask questions about the content too.
    By returning the content you can also read e.g. the content on a website or inside a file.
    """
    return uri


@mcp.tool()
def search_existing_tasks(description: str, limit:int=10) -> typing.List[Task]:
    """lookup existing tasks that match a description. You should do this before creating a new similar tasks and apply description merging
    """
    return "TEST"

@mcp.tool()
def update_task(task:Task) -> Task:
    """upsert a task by name and merged content
    """
    return task
 
@mcp.tool()
def add_content(uri:str) :
    """upload content which can be a website or file
    """
    pass
 

