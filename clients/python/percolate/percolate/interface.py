from .services.PostgresService import PostgresService
from .models import AbstractModel
import typing
from pydantic import BaseModel
from .services.ModelRunner import ModelRunner
from .services import OpenApiService

def dump(*args,**kwargs):
    """TODO:"""
    pass


def get_entities(keys: str | typing.List)->typing.List[dict]:
    """
    get entities from their keys in the database
    
    **Args:
        keys: one or more keys 
    """

    data =  PostgresService().get_entities(keys)
 
    return data

def repository(model:AbstractModel|BaseModel):
    """gets a repository for the model. 
    This provides postgres services in the context of the type
    
    Args:
        model: a Pydantic base model or AbstractModel
    """
    return PostgresService(model)

def Agent(model:AbstractModel|BaseModel, **kwargs):
    """get the model runner in the context of the agent for running reasoning chains"""
    return ModelRunner(model,**kwargs)

def run(question: str, agent: str, limit_turns:int=2, **kwargs):
    """optional entry point to run an agent in the database by name
    The limit_turns controls how many turns are taken in the database e.g. call a tool and then ask  the agent to interpret 
    Args:
        question (str): any question for your agent
        agent: qualified agent name. Default schema is public and can be omitted
        limit_turns: limit turns 2 allows for a single too call and interpretation for example
    """
    if '.' not in agent:
        agent = f"public.Agent"
    return PostgresService().execute(f""" select * from percolate_with_agent('{question}', '{agent}', {limit_turns}); """, )    
    
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
    if 'http' in proxy_uri or 'https' in proxy_uri:
        return OpenApiService(proxy_uri)
    if 'p8.' in proxy_uri:
        return PostgresService()
    
    raise NotImplemented("""We will add a default library proxy for the functions in the library 
                         but typically the should just be added at run time _as_ callables since 
                         we can recover Functions from callables""")
    
def get_planner()->typing.Callable:
    """retrieves a wrapper to the planner agent which takes a question for planning
    
    """
    from percolate.models.p8 import Function,PlanModel
    from functools import partial
    a = Agent(PlanModel,allow_help=False, init_data =repository(Function).select())
    return a