from .services.PostgresService import PostgresService
from .models import AbstractModel
import typing
from pydantic import BaseModel
from .services.ModelRunner import ModelRunner
from .services import OpenApiService

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

def get_language_model_settings():
    """iterates through language models configured in the database.
    this is a convenience as you can also select * from p8."LanguageModelApi"
    """
    
    return PostgresService().execute('select * from p8."LanguageModelApi"')


def get_proxy(proxy_uri:str):
    """A proxy is a service that can call an external function such as an API or Database.
    We can theoretically proxy library functions but in python they should be added to the function manager as callables instead
    
    Args:
        proxy_uri: an openapi rest api or a native schema name for the database - currently the `p8` schema is assumed
    """
    if 'http' or 'https' in proxy_uri:
        return OpenApiService(proxy_uri)
    if 'p8.' in proxy_uri:
        return PostgresService()
    
    raise NotImplemented("""We will add a default library proxy for the functions in the library 
                         but typically the should just be added at run time _as_ callables since 
                         we can recover Functions from callables""")