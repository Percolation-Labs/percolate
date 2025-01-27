from .services.PostgresService import PostgresService
from .models import AbstractModel
import typing
from pydantic import BaseModel
from .services.ModelRunner import ModelRunner

def dump(*args,**kwargs):
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

def Agent(model:AbstractModel|BaseModel):
    """get the model runner in the context of the agent for running reasoning chains"""
    return ModelRunner(model)