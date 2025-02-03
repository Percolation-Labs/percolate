#!/usr/bin/env python

from percolate.utils import logger
import sys
logger.remove()  
logger.add(sys.stderr, level="INFO")  # Set log level to info for typer since DEBUG is default

import typer
from typing import List, Optional
from percolate.utils.ingestion import add
from percolate.utils.env import sync_model_keys
import percolate as p8
from percolate.models.p8 import PercolateAgent


app = typer.Typer()

add_app = typer.Typer()
app.add_typer(add_app, name="add")

@add_app.command()
def api(
    uri: str = typer.Argument(..., help="The API URI"),   
    name: Optional[str] = typer.Option(None, help="A friendly optional API name - the uri will be as a default name"),
    token: Optional[str] = typer.Option(None, help="Authentication token for the API"),
    file: Optional[str] = typer.Option(None, help="File associated with the API"),
    verbs: Optional[List[str]] = typer.Option(None, help="HTTP verbs allowed (e.g., GET, POST)"),
    filter_ops: Optional[str] = typer.Option(None, help="Filter operations as a string expression")
):
    """Add an API configuration."""
    typer.echo(f"Adding API: {name}")
    typer.echo(f"URI: {uri}")
    add.add_api(name=name, uri=uri, token=token,file=file, verbs=verbs,filter_ops=filter_ops)

@add_app.command()
def env(
    sync: bool = typer.Option(False, "--sync", help="Sync environment variables from .env")
):
    """Add environment variables via key-value pairs or sync from .env file"""
    if sync:
        typer.echo('---------------------------------------------------------------------------')
        typer.echo(f"🔄 Syncing env vars from your environment for loaded models in percolate.")
        typer.echo('---------------------------------------------------------------------------')
        results = sync_model_keys()
        count = 0
        for key, result in results.items():
            if result:
                count += 1
            typer.echo(f"{'✅' if result else '❌'} {key}")
        if count:
            typer.echo('-----------------------------------------------------------')
            typer.echo(f'Added {count} keys - see the p8."LanguageModelApi" table.')
            typer.echo('-----------------------------------------------------------')
        else:
            typer.echo('-----------------------------------------------------------')
            typer.echo(f'did not find any suitable keys in your environment.')
            typer.echo('-----------------------------------------------------------')
                
@add_app.command()
def function(
    name: str,
    file: str,
    args: Optional[str] = typer.Option(None, help="Arguments for the function"),
    return_type: Optional[str] = typer.Option(None, help="Return type of the function")
):
    """Add a function configuration."""
    typer.echo(f"Adding Function: {name}")
    typer.echo(f"File: {file}")
    if args:
        typer.echo(f"Args: {args}")
    if return_type:
        typer.echo(f"Return Type: {return_type}")

@add_app.command()
def agent(
    name: str,
    endpoint: str,
    protocol: Optional[str] = typer.Option("http", help="Communication protocol (default: http)"),
    config_file: Optional[str] = typer.Option(None, help="Path to the agent configuration file")
):
    """Add an agent configuration."""
    typer.echo(f"Adding Agent: {name}")
    typer.echo(f"Endpoint: {endpoint}")
    typer.echo(f"Protocol: {protocol}")
    if config_file:
        typer.echo(f"Config File: {config_file}")


# Index command with no arguments
@app.command()
def index():
    """Index the codebase (no arguments)."""
    from percolate.utils.index import index_codebase
    index_codebase()

# Ask command with a default question parameter and flags for agent and model
@app.command()
def ask( 
    question: str = typer.Argument("What is the meaning of life?", help="The question to ask"),
    agent: str = typer.Option(None, help="The agent to use"),
    model: str = typer.Option(None, help="The model to use")
):
    
    from percolate.utils.env import DEFAULT_MODEL
    typer.echo(f"Asking percolate...")
    """temp interface todo: - trusting the database is what we want but will practice with python
    
    example after indexing 
    python percolate/cli.py ask 'are there SQL functions in Percolate for interacting with models like Claude?'
    """
    #data  = p8.repository(PercolateAgent).execute(f"""  SELECT * FROM percolate_with_agent('{question}', '{agent or 'p8.PercolateAgent'}', '{model or DEFAULT_MODEL}') """)
    from percolate.models.p8 import PercolateAgent
    from percolate.services.llm import CallingContext
    
    def printer(text):
        """streaming output"""
        print(text, end="", flush=True)  
        if text == None:
            print('')
            
    
    c = CallingContext(streaming_callback=printer)
    agent = p8.Agent(PercolateAgent)
    data = agent(question,context=c)
    typer.echo('')        
    if data:
        pass
        #typer.echo(f"Session({data[0]['session_id_out']}): {data[0]['message_response']}")
        #typer.echo(data)
    else:
        typer.echo(f"Did not get a response")

if __name__ == "__main__":
    app()
