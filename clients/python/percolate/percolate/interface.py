from .services.PostgresService import PostgresService
from .models import AbstractModel
import typing
from pydantic import BaseModel
from .services.ModelRunner import ModelRunner
from .services import OpenApiService
from .models.p8.db_types import AskResponse
import json
from percolate.models.inspection import load_model
import percolate as p8
from percolate.models.p8 import Session,AIResponse
from percolate.utils import logger
import traceback
from percolate.utils.env import SETTINGS

def settings(key, default=None):
    return SETTINGS.get(key,default)

def dump(question:str, data: typing.List[dict], response:AIResponse, context, **kwargs):
    """we dump the session using the session id from the AI response and we dump the final response"""
    try:
        p8.repository(Session).update_records(Session.from_question_and_context(id=response.session_id, 
                                                                                question=question,
                                                                                context=context, 
                                                                                agent=kwargs.get('agent')))
        """we could dump data but lets not for now"""
        p8.repository(AIResponse).update_records(response)
    except:
        logger.warning(f"Failed to dump session  -  {traceback.format_exc()}")

def describe_agent(agent: AbstractModel | str, include_native_tools:bool=False):
    """
    Provides a description of the agent model as it would be passed to an LLM
    """
    
    if isinstance(agent,str):
        prompt = PostgresService().execute(f""" select * from p8.generate_markdown_prompt(%s) """, data=(agent,))
        prompt = prompt[0]['generate_markdown_prompt'] if prompt else None
        functions = PostgresService().execute(f""" select * from p8.get_agent_tools(%s,NULL,%s) """, data=(agent,include_native_tools))
        if functions:
            functions = functions[0]['get_agent_tools']
            #form canonical format
            functions = [f['function'] for f in functions]
            #to dict
            functions = {f['name']: f['description'] for f in functions}
        else:
            functions = {}
    else:
        agent = AbstractModel.Abstracted(agent)
        prompt =  agent.get_model_description()
        functions = agent.get_model_functions()
 
    function_desc = ""
    for k,v in (functions or {}).items():
        function_desc+=f""" - **{k}**: {v}\n"""

    prompt += f"""
    
## Functions
{function_desc}
    """
    
    return prompt

def summarize(data:str,context:str):
    """summarize data based on context"""
    from percolate.services.llm.LanguageModel import request_openai, MessageStack
    from percolate.utils import logger
    
    logger.debug('Summarizing data...')    
    
    Q = f"""please summarize the data below based on this context
    
    ## Context
    ```
    {context}
    ```
    
    ## Data
    ```
    {data}
    ```
    """
    

    stack = MessageStack(Q, "be efficient - keep only what is useful in context")
    return request_openai(stack,None)
    

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

def Agent(model:AbstractModel|BaseModel, allow_help:bool=True, **kwargs)->ModelRunner:
    """get the model runner in the context of the agent for running reasoning chains
    
    The Allow help is important to consider because it can lead to cascades percolating to far. a depth parameter might be interesting
    """
    return ModelRunner(model, allow_help=allow_help, **kwargs)

def resume(session: AskResponse|str) ->AskResponse:
    """
    pass in a session id or ask response object to resume the session
    Resume session continues any non completed session
    """
    
    if isinstance(session,AskResponse):
        session = session.session_id
    
    response =  PostgresService().execute(f""" select * from p8.resume_session(%s); """, data=(session,) )    
    if response:
        print(response)
        return AskResponse(**response[0])
    else:
        raise Exception("Percolate gave no response")
    
    
def run(question: str, agent: str=None, limit_turns:int=2, **kwargs):
    """optional entry point to run an agent in the database by name
    The limit_turns controls how many turns are taken in the database e.g. call a tool and then ask  the agent to interpret 
    Args:
        question (str): any question for your agent
        agent: qualified agent name. Default schema is public and can be omitted - defaults to p8.PercolateAgent
        limit_turns: limit turns 2 allows for a single too call and interpretation for example
    """
    if not agent:
        agent = f"p8.PercolateAgent"
    elif '.' not in agent:
        agent = f"public.{agent}"
        
    response =  PostgresService().execute(f""" select * from percolate_with_agent(%s, %s); """, data=(question, agent) )    
    if response:
        print(response)
        return AskResponse(**response[0])
    else:
        raise Exception("Percolate gave no response")
    
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
    if "p8agent/" in proxy_uri:
        """we create a p8 agent proxy to the entity name - the proxy in the database is p8agent/agent.name - see Function.from_entity"""
        entity_name = proxy_uri.split('/')[-1]
        class _agent_proxy:
            def __init__(self, entity_name):
                """TODO: consider if we want to not allow help at depth!!!!!!"""
                self.agent = Agent(load_model(entity_name),allow_help=False)
                
            def invoke(self, fn, **kwargs):
                #print(f"**TESTING - calling proxy agent with {kwargs}")
                """provide a proxy that takes the function but hard code as run for now anyway"""
                data  = self.agent.run(**kwargs)
                #print(f"**TESTING - got data {data}")
                return data
                
        """here we are percolating by loading the context fully for that agent - we could do a context transfer in future too"""
        return _agent_proxy(entity_name=entity_name)
    
    if 'http' in proxy_uri or 'https' in proxy_uri:
        return OpenApiService(proxy_uri)
    if 'p8.' in proxy_uri:
        return PostgresService()
    
    raise NotImplementedError(f"""We will add a default library proxy for the functions in the library 
                         but typically the should just be added at run time _as_ callables since 
                         we can recover Functions from callables - {proxy_uri}""")
    
def get_planner()->typing.Callable:
    """retrieves a wrapper to the planner agent which takes a question for planning
    
    """
    from percolate.models.p8 import Function,PlanModel
    from functools import partial
    a = Agent(PlanModel,allow_help=False, init_data =repository(Function).select())
    return a