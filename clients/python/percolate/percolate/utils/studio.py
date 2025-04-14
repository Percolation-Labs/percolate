import yaml
from glob import glob
from percolate.utils.env import STUDIO_HOME, TAVILY_API_KEY
from pydantic import BaseModel,Field,model_validator
import typing
import os 
from percolate.utils import logger,make_uuid
import percolate as p8
from percolate.models.p8 import Task, ResearchIteration, Function, Resources
from percolate.services.OpenApiService import OpenApiSpec
       

class ProjectAgents(BaseModel):
    name: str
    description: str
    functions: typing.Optional[dict] = Field(default_factory=dict)
    spec: dict
    
class ProjectApis(BaseModel):
    name:str
    uri: str = Field(alias='openapi-uri')
    verbs: typing.Optional[typing.List[str]] = Field(default_factory=list)
    filter_ops:typing.Optional[typing.List[str]] = Field(default_factory=list)
    token: typing.Optional[str] = Field(None, description="add the token env in files and we will add it from env")
    token_env: typing.Optional[str] = Field(None, description="add the token env in files and we will add the token from env",exclude=True)
    alt_host: typing.Optional[str] = Field(None, description="The alternate host can use a different domain name eg. for docker")
    
    @model_validator(mode='before')
    @classmethod
    def _val(cls, values):
        if not values.get('token') and values.get('token_env'):
            values['token'] = os.environ.get(values.get('token_env'))
        return values
    
def add_percolate_endpoints(filter_ops: typing.List[str], uri:str=None,alt_host:str=None):
    """
    
    """
    
    """the dev server or the docker one
    to test these its easiest to stop the docker service and start dev server on 5008
    """
    uri = uri or f"http://percolate-api:5008/openapi.json"
    
    logger.info(f"Adding percolate endpoints {filter_ops}")
    service = OpenApiSpec(uri,alt_host=alt_host)
    repo = p8.repository(Function)
    repo.update_records(list(service.iterate_models(filter_ops=filter_ops)))
    
class ProjectModels(BaseModel):
    name: str
    completions_uri: str
    scheme: str
    token: typing.Optional[str] = Field(None, description="add the token env in files and we will add it from env")
    token_env: typing.Optional[str] = Field(None, description="add the token env in files and we will add the token from env",exclude=True)
    
    @model_validator(mode='before')
    @classmethod
    def _val(cls, values):
        if not values.get('token') and values.get('token_env'):
            values['token'] = os.environ.get(values.get('token_env'))
        return values
    
class Project(BaseModel):
    name: str
    database: typing.Optional[str] = Field('app', description="the database to add data to for the project")
    options: dict
    models: typing.Optional[ProjectModels]
    apis: typing.Optional[typing.List[ProjectApis]]
    models: typing.Optional[typing.List[ProjectModels]]
    agents: typing.Optional[typing.List[ProjectAgents]]
    

def open_project(name:str)->dict:
    """opens a project file in studio by folder name
    the project file is a percolate.yaml but we will also compile multiple files e.g. agents, apis etc in future
    TODO: create a pydantic parser for the project file
    """
    
    
    files = list(glob(f"{STUDIO_HOME.rstrip('/')}/projects/{name}/*.yaml"))
    yaml_file_mergeable = {}
    for f in files:
        with open(f, 'r') as f:
            yaml_file_mergeable.update(yaml.safe_load(f))
            
    try:
        return Project(**yaml_file_mergeable.get('project'))
    except Exception as ex:
        logger.warning(f"Unable to parse the file -{ex} - will return the contents so you can check it ")
        return yaml_file_mergeable
    
def apply_project(project:Project|str):
    """
    logic to apply a project to the database
    """
    from percolate.utils.ingestion import add
    from percolate.utils.index import index_codebase
    from percolate.utils.env import sync_model_keys
    from percolate.models.p8 import ApiProxy
    
    if isinstance(project,str):
        project = open_project(project)
    opts = project.options or {}
    if opts.get('sync-env'):
        sync_data = sync_model_keys()
        logger.info(f"im syncing env keys if they are set for language model providers - will add to your database - {sync_data}")
    if opts.get('index-docs'):
        index_codebase()
    
    for api in project.apis:
        add.add_api(api.name, 
                    api.uri, 
                    api.token,
                    None, 
                    verbs=api.verbs, 
                    filter_ops=api.filter_ops,
                    alt_host=api.alt_host)
    #if configured
    if TAVILY_API_KEY:
        logger.info(f"Adding the tavily search api using the key in the environment")
        uri = 'https://api.tavily.com/search'
        p = ApiProxy(id=make_uuid({'proxy_uri':uri}),proxy_uri=uri, token=TAVILY_API_KEY)
        p8.repository(ApiProxy).update_records(p)
        
    #we can maybe add the Task and ResearchIteration as agent functions
    #any agent can be added as a function which makes it recruitable but we are not doing it by default for now

    p8.repository(Function).update_records(
        [
            Function.from_entity(Task),
            Function.from_entity(Resources),
            Function.from_entity(ResearchIteration),
        ]
    )
    
    """add some endpoints as functions to percolate api"""
    add_percolate_endpoints(['create_task_tasks__post', 
                             'execute_research_iteration_tasks_research_execute_post'])
        
    """TODO"""
    return {'status':'ok'}