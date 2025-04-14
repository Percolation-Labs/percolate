#!/usr/bin/env python

from percolate.utils import logger
import sys
logger.remove()  
logger.add(sys.stderr, level="INFO")  # Set log level to info for typer since DEBUG is default
import time
import typer
from typing import List, Optional
from percolate.utils.ingestion import add
from percolate.utils.env import sync_model_keys
import percolate as p8
from percolate.models.p8 import PercolateAgent
import webbrowser
import requests
import os
import json
from pathlib import Path
import yaml
from percolate.models import Resources

app = typer.Typer()

add_app = typer.Typer()
app.add_typer(add_app, name="add")

admin_app = typer.Typer()
app.add_typer(admin_app, name="admin")

"""publish app

<> container . -t "3.2.1" 
"""
publish_app = typer.Typer()
app.add_typer(publish_app, name="publish")


PERCOLATE_DOMAIN = "www.percolationlabs.ai"

def authenticate_and_save():
    """
    This is used if you want to fetch a service account from percolate
    """
    
    def poll_for_key(key_url, timeout=60, interval=3):
        """
        Polls the server for the service account key. requires login from the user in the web browser
        """
        elapsed_time = 0
        while elapsed_time < timeout:
            response = requests.get(key_url)
            if response.status_code == 200:
                return response.json()
            
            typer.echo("Waiting for authentication to complete...")
            time.sleep(interval)
            elapsed_time += interval
        
        typer.echo("Authentication timed out. Please try again.")
        return None

    AUTH_URL = f"https://{PERCOLATE_DOMAIN}/auth/login?fetch_key=True"
    webbrowser.open(AUTH_URL)
    typer.echo("Please complete the authentication in your browser...")
    credentials_data = poll_for_key(f"https://{PERCOLATE_DOMAIN}/auth/service-key")
    
    if credentials_data:
        config_path = os.path.expanduser("~/.percolate")
        os.makedirs(config_path, exist_ok=True) 
        account_file = os.path.join(config_path, "service.json")
        with open(account_file, "w") as f:
            json.dump(credentials_data, f, indent=4)
        typer.echo(f"Authentication successful! Credentials saved to {account_file}")
    else:
        typer.echo("Failed to retrieve authentication key. Please try again.")

def _load_resources_from_spec(spec_path: Path) -> List["Resources"]:
    with open(spec_path, 'r') as f:
        spec_data = yaml.safe_load(f)

    all_resources = []
    for entry in spec_data:
        entry_uri = entry.get("uri")
        if not entry_uri:
            typer.echo("Each item in spec must contain a 'uri'", err=True)
            continue

        chunk_size = entry.get("chunk_size", 1000)
        category = entry.get("category")
        name = entry.get("name")

        resources = Resources.chunked_resource(
            uri=entry_uri,
            chunk_size=chunk_size,
            category=category,
            name=name,
        )
        all_resources.extend(resources)

    return all_resources

@add_app.command("files")
def add_files(
    uri: Optional[str] = typer.Argument(None, help="The file path or URL to chunk"),
    chunk_size: int = typer.Option(1000, "--chunk-size", "-c", help="Size of each text chunk"),
    category: Optional[str] = typer.Option(None, help="Optional content category"),
    name: Optional[str] = typer.Option(None, help="Optional name for the resource"),
    spec: Optional[Path] = typer.Option(None, "--spec", "-s", exists=True, help="Path to YAML file with resource definitions"),
):
    """Add files by url - you can add a collection of files by providing an input spec as a collection of the same arguments"""
    if not uri and not spec:
        typer.echo("You must provide either a URI or a --spec file.", err=True)
        raise typer.Exit(code=1)

    """
    #from poetry we run it like this
    poetry run p8 add files https://arxiv.org/pdf/2404.16130
    
    # and then you should be able to ask
    poetry run p8 ask "do we have any resources about local to global rag"
    """
    
    repo = p8.repository(Resources)
    
    if not repo.entity_exists:
        repo.register()
            
    all_resources = []
    if spec:
        all_resources = _load_resources_from_spec(spec)
    else:
        all_resources = Resources.chunked_resource(
            uri=uri,
            chunk_size=chunk_size,
            category=category,
            name=name,
        )
        
    repo.update_records(all_resources)
    """optionally upload to s3 storage for record keeping later"""

    # Do something with all_resources
    typer.echo(f"Saved {len(all_resources)} resources ✅")
     
@admin_app.command()
def admin_login():
    """login to get a local key for authenticated use with percolate server and your database instance"""
    
    #when the user logs in we fetch the service account that stores their api key
    #we can do some things like IP whitelisting and billing configuration
    authenticate_and_save()
    
@admin_app.command()
def billing():
    """Login to add a payment method to provision percolate resources"""
    AUTH_URL = f"https://{PERCOLATE_DOMAIN}/admin/billing"
    webbrowser.open(AUTH_URL)
    
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

@app.command()
def init(
    name: str = typer.Argument("default", help="The name of the project to apply"),
):
    from percolate.utils.studio import apply_project
    typer.echo(f"I'll apply project [{name}] to the database")
    status = apply_project(name)
    
    
@app.command()
def connect(project_name: str, 
             token: str = typer.Option(..., "--token", help="Bearer token for authentication")):
    """Connect to the project and save authentication details."""
    url = f"https://{project_name}.percolationlabs.ai/auth/connect"
    headers = {"Authorization": f"Bearer {token}"}
    
    response = requests.get(url, headers=headers)
    
    if response.status_code == 200:
        home = Path.home()
        percolate_dir = home / ".percolate" / 'auth'
        percolate_dir.mkdir(exist_ok=True, parents=True)
        
        #match user_percolate_home in env
        token_path = percolate_dir  / "token"
        token = response.json()
        with token_path.open("w") as f:
            json.dump(token, f, indent=4)
        
        typer.echo(f"Successfully connected [{token.get('P8_PG_HOST')}] and token saved")
    else:
        typer.echo(f"Failed to connect at {url}: {response.status_code} {response.text}", err=True)


                
@publish_app.command( )
def api(path: str = typer.Option('.', help="Docker context path such as .")):
    """Add a function configuration."""
    typer.echo(f"Publishing : {path}")
    from percolate.utils.cloud import docker_login_and_push_from_project
    docker_login_and_push_from_project(path)

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
    agent = p8.Agent(PercolateAgent) if agent is None else p8.Agent(p8.load_model(agent))
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

#TODO: add diff and file based migration to database from staging sql