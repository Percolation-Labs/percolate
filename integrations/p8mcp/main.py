

from mcp.server.fastmcp import FastMCP
import requests
import typing
from pydantic import BaseModel

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


@mcp.tool()
def ask_percolate(query:str) -> str:
    """ask anything of the percolate agent"""
    return "TEST"

@mcp.tool()
def web_search(query:str) -> typing.List[SearchResult]:
    """query the web with a search query and receive a list of summarized results"""
    return [SearchResult(url='http://whatever', content="test", summary="test")]

 
@mcp.tool()
def fetch_recent_email(limit:int=5,filter_domain:str=None) -> typing.List[SearchResult]:
    """fetch recent emails for the user limited by parameter default to 5. Optionally filter emails from a domain
    """
    return [SearchResult(url='http://whatever', content="test", summary="test")]

@mcp.tool()
def add_resource(uri:str, comment:str=None) -> str:
    """add a resource such as website or file with an optional comment.
    this can be used to make extra content available to the session and you can ask questions about the content too
    """
    return "TEST"

@mcp.tool()
def get_entities(keys: typing.List[str]) -> str:
    """supply one or more entity keys to get details about them. 
    entities can be tasks by name, resources by uri or any other entity encountered in the session and stored in Percolate.
    this is a generic function to lookup any such named resource.
    """
    return "TEST"



#set/update task - we will load an existing task when doing this so there is no get as such
#set/get web content