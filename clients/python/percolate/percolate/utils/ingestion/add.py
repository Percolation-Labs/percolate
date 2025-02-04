import typing
import percolate as p8
from percolate.models.p8 import ApiProxy, Function
from percolate.utils import logger

def add_api(name:str, uri:str, token:str=None, file:str=None, verbs: str | typing.List[str]=None, filter_ops: typing.Optional[str]=None, alt_host:str=None):
    """
    Add an api by name and uri to json spec
    
    configuration files are json or yaml files for example
    
    ```yaml
    type: api
    name: unique.name
    functions:
        - name: the op id or endpoint
          description: a description that augments the one in the spec        
    ```
    
    Example add
    ```python
    add_api('percolate-api', 'http://127.0.0.1:5000/openapi.json', token=load_db_key(), alt_host='http://percolate-api:5008')
    ```
    
    Args:
        name: the unique name of the api
        uri: the uri to where the spec lives as openapi.json e.g https://petstore.swagger.io/v2/swagger.json
        token: optional bearer token
        file: a configuration file 
        verbs: a command separated list or string list of verbs e.g. get,post to filter for ingestion
        filter_ops: an operation/endpoint filter list to endpoint ids
        alt_host: use an alternate host after fetching the openapi.json and saving to the database for example if your API lives on a docker image or K8s. you should include the domain
    """
    from percolate.services.OpenApiService import OpenApiSpec
      
    service = OpenApiSpec(uri,alt_host=alt_host)
    logger.info(f"Adding API {uri=}")
    """register the api"""
    p8.repository(ApiProxy).update_records(ApiProxy(name=name, proxy_uri=service.host_uri,token=token))
    """register the functions"""
    repo = p8.repository(Function)
    repo.update_records(list(service.iterate_models(verbs=verbs, filter_ops=filter_ops)))
    logger.debug(f"Added api {uri=}")
    
    

def add_agent(name:str,  file:str ):
    """
    Add an agent by name and configuration file
    
    configuration files are json or yaml files for example
    
    ```yaml
    type: agent
    name: unique.name
    spec: -|
      {}
    description: a system prompt
    functions:
        - name: the name of the function in percolate
          description: a description that augments the one in the spec        
    ```
    
    Args:
        name: the unique name of the api
        file: a configuration file 
    """
    
    raise NotImplementedError("This one is coming")
    