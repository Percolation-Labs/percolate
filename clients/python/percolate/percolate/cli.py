#!/usr/bin/env python
import typer
from typing import List, Optional
from percolate.utils.ingestion import add
from percolate.utils.env import sync_model_keys
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
        typer.echo(f"Syncing env vars from your environment for loaded models in percolate. See p8.LanguageModelApi table.")
        results = sync_model_keys()
        for key, result in results.items():
            typer.echo(f"{'✅' if result else '❌'} {key}")
            
    
                
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

if __name__ == "__main__":
    app()
