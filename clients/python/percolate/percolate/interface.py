from .services.PostgresService import PostgresService
from .models import AbstractModel
import typing
from pydantic import BaseModel

def dump(**kwargs):
    """TODO:"""
    pass

def get_entities(keys: str | typing.List):
    """
    get entities from their keys in the database
    """

    return PostgresService().get_entities(keys)

def repository(model:AbstractModel|BaseModel):
    """gets a repository for the model. 
    This provides postgres services in the context of the type
    
    Args:
        model: a Pydantic base model or AbstractModel
    """
    return PostgresService(model)