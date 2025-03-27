import yaml
import json
import os
import requests
from functools import partial
from percolate.models.p8 import Function,ApiProxy
import typing
from percolate.utils import logger
from urllib.parse import urlparse
import percolate as p8


class  _ApiTokenCache:
    def __init__(self):
        self.cache = {}
        
    def get(self, key:str):
        """
        simple cached lookup of api tokens
        """    
        if key not in self.cache:
            records = p8.repository(ApiProxy).select(proxy_uri=key)
            if records:
                self.cache[key] = records[0]['token']
        return self.cache[key]
    
_ApiTokenCache = _ApiTokenCache()
    
def map_openapi_to_function(spec,short_name:str=None):
    """Map an OpenAPI endpoint spec to a function ala open AI
       you can add functions from this to the tool format with for example
       
       ```python
       fns = [map_openai_to_function(openpi_spec_json['/weather']['get'])]
       tools = [{'type': 'function', 'function': f} for f in fns]
       ```
       
       TODO: create a pydantic model for this but for now im just trying to understand it and see who complains
    """
    def _map(schema):
        """
        Recursively map the parameters containing schema to a flatter representation,
        retaining only 'type', 'description', and optional 'enum' in nested types.
        """
        if 'schema' in schema:
            schema = schema['schema']
        mapped_schema = {
            #TODO i need to understand the spec better
            'type': schema.get('type','string'),
            'description': schema.get('description', '')  
        }
        
        
        if 'enum' in schema:
            mapped_schema['enum'] = schema['enum']

        if schema.get('type') == 'array' and 'items' in schema:
            mapped_schema['items'] = _map(schema['items'])

        if schema.get('type') == 'object' and 'properties' in schema:
            mapped_schema['properties'] = {k: _map(v) for k, v in schema['properties'].items()}

        return mapped_schema
        
    try:
        parameters = {p['name']: _map(p) for p in (spec.get('parameters') or [])}
        required_params = [p['name'] for p in spec.get('parameters') or [] if p.get('required')]

        request_body = (spec.get('request_body') or {})#.get('properties', {})#.get('application/json', {}).get('schema')
        # Handle request body if present
        if request_body:
            body_schema = request_body
            parameters['request_body'] =  request_body
            if 'required' in body_schema:
                required_params.extend(body_schema['required'])

        r = {
            'name': short_name or (spec.get('operationId') or spec.get('title')),
            'description': spec.get('description') or spec.get('summary'),
            'parameters': {
                'type': 'object',
                'properties': parameters,
                'required': required_params
            }
        }
  
    except:
        logger.warning(f"Failing to parse {spec=}")
        raise
    return r

    
class OpenApiSpec:
    """
    The spec object parses endpoints into function descriptions
    """
    def __init__(self, uri_or_spec: str| dict, token_key:str=None, alt_host: str=None):
        """supply a spec object (dict) or a uri to one
        The alt hose can be used if you are mapping the json from one place but invoke the server on another e.g. docker or kubernetes
        """
        self._spec_uri_str = ""
        if isinstance(uri_or_spec,str):
            self._spec_uri_str = uri_or_spec
            if uri_or_spec[:4].lower() == 'http':
                uri_or_spec = requests.get(uri_or_spec)
                if uri_or_spec.status_code == 200:
                    uri_or_spec = uri_or_spec.json()
                else:
                    raise Exception(f"unable to fetch {uri_or_spec}")
            else:
                with open(uri_or_spec, "r") as file:
                    uri_or_spec = yaml.safe_load(file)
                    
        if not isinstance(uri_or_spec,dict):
            raise ValueError("Unable to map input to spec. Ensure spec is a spec object or a uri pointing to one")

        self.spec = uri_or_spec
        """going to assume HTTPS for now TODO: consider this"""
        if 'host' in self.spec:
            self.host_uri = alt_host or f"https://{self.spec['host']}"
            if 'basePath' in self.spec:
                self.host_uri += self.spec['basePath']
        else:
            """by convention we assume the uri is the path without the json file"""
            parsed_url = urlparse(self._spec_uri_str)
            self.host_uri = alt_host or  f"{parsed_url.scheme}://{parsed_url.netloc}"

        self.token_key = token_key
        """lookup"""
        self._endpoint_methods = {op_id: (endpoint,method) for op_id, endpoint, method in self}
        self.short_names = self.map_short_names()
        
    @property
    def spec_uri(self):
        return self._spec_uri_str
    
    def map_short_names(self):
        """in the context we assume a verb and endpoint is unique"""
        d = {}
        for k,v in self._endpoint_methods.items():
            endpoint, verb = v
            """we just flatten and remove leading / - it may be that we dont want to keep the trailing / that becomes _ as its just weird - but not sure rules of uniqueness """
            d[f"{verb}_{endpoint.lstrip('/').replace('/','_').replace('-','_').replace('{','').replace('}','')}"] = k
        return d
    
    def iterate_models(self,verbs: str | typing.List[str]=None, filter_ops: typing.Optional[str]=None):
        """yield the function models that can be saved to the database
        
        Args:
           verbs: a command separated list or string list of verbs e.g. get,post to filter for ingestion
           filter_ops: an operation/endpoint filter list to endpoint ids
        """
        
        """treat params"""
        verbs=verbs.split(',') if isinstance(verbs,str) else verbs
        filter_ops=verbs.split(',') if isinstance(filter_ops,str) else filter_ops
        
        ep_to_short_names = {v:k for k,v in self.short_names.items()}
        #spec = self.get_expanded_schema()
        """we can use self.spec['paths'] which is not expanded"""
        for endpoint, grp in self.spec['paths'].items():
            for method, s in grp.items():
                op_id = s.get('operationId')
                
                if verbs and method not in verbs:
                    continue
                if filter_ops and op_id not in filter_ops:
                    continue
                """when generating we need to expand the endpoint schema"""
                s = self.get_expanded_schema_for_endpoint(endpoint,method)
         
                fspec = map_openapi_to_function(s,short_name=ep_to_short_names[op_id])
                yield Function(name=ep_to_short_names[op_id],
                               key=op_id,
                               proxy_uri=self.host_uri,
                               function_spec = fspec,
                               verb=method,
                               endpoint=endpoint,
                               description=s.get('description') or s.get('summary') or s.get('title'))
                    
        
    def __repr__(self):
        """
        """
        return f"OpenApiSpec({self._spec_uri_str})"
    
    def __getitem__(self,key):
        if key not in self._endpoint_methods:
            if key in self.short_names:
                key = self.short_names[key]
            else:
                raise Exception(f"{key=} could not be mapped to an operation id or shortened name verb_endpoint")
        return self._endpoint_methods[key]
    
    def get_operation_spec(self, operation_id):
        """return the spec for this function given an endpoint operation id"""
        endpoint, verb = self._endpoint_methods[operation_id]
        return self.spec['paths'][endpoint][verb]
            
    def get_endpoint_method_from_route(self, route):
        """ambiguous and uses the first"""
        op_id = {k[0]:v for v,k in self._endpoint_methods.items()}.get(route)
        return self._endpoint_methods.get(op_id)
    
    def get_endpoint_method(self, op_id):
        """pass the operation id to get the method"""
        op =  self._endpoint_methods.get(op_id)
        if not op:
            """try the reverse mapping"""
            return self.get_endpoint_method_from_route(op_id)
        return op
    
    def resolve_ref(self, ref: str):
        """Resolve a $ref to its full JSON schema."""
        parts = ref.lstrip("#/").split("/")
        resolved = self.spec
        for part in parts:
            resolved = resolved[part]
        return resolved

    def __iter__(self):
        """iterate the endpoints with operation id, method, endpoint"""
        for endpoint, grp in self.spec['paths'].items():
            for method, s in grp.items():
                op_id = s.get('operationId')
                yield op_id, endpoint, method

    def get_expanded_schema(self):
        """expand the lot map to operation id"""
        
        def _pack(endpoint,method,expanded):
            return {'endpoint':endpoint,'methods': {method: expanded}}
        
        return {operation_id: self.get_expanded_schema_for_endpoint(endpoint, method)   
                for operation_id, endpoint, method in self}
            
    def get_expanded_schema_for_endpoint(self, endpoint: str, method: str):
        """Retrieve the expanded JSON schema for a given endpoint and HTTP method."""
        parameters = []
        request_body = None
        spec = self.spec
        
        method_spec = spec["paths"].get(endpoint, {}).get(method, {})

        # Process query/path/header parameters
        for param in method_spec.get("parameters", []):
            param_schema = param.get("schema", {})
            if "$ref" in param_schema:
                param_schema = self.resolve_ref(param_schema["$ref"])
            parameters.append({
                "name": param["name"],
                "in": param["in"],
                "description": param.get("description", ""),
                "schema": param_schema
            })

        # Process requestBody (e.g., for POST requests)
        if "requestBody" in method_spec:
            content = method_spec["requestBody"].get("content", {})
            if "application/json" in content:
                schema = content["application/json"].get("schema", {})
                if "$ref" in schema:
                    schema = self.resolve_ref(schema["$ref"])
                request_body = schema

        method_spec['parameters'] = parameters
        method_spec['request_body'] = request_body
        
        return method_spec
    
    
class OpenApiService:
    def __init__(self, uri, token_or_key:str=None, spec: OpenApiSpec=None):
        """a wrapper to invoke functions"""
        
        self.uri = uri
        self.spec = spec
        """assume token but maybe support mapping from env"""
        self.token = token_or_key or _ApiTokenCache.get(uri)
         
    def invoke(self, function:Function, request_body:dict=None, p8_return_raw_response:bool=False, p8_full_detail_on_error: bool = False,  **kwargs):
        """we can invoke a function which has the endpoint information
        
        Args:
            function: This is a wrapped model for an endpoint stored in the database
            data: this is post-like data that can be posted for testing endpoints and we can alternative between data and kwargs
            p8_return_raw_response: a debugging/testing tool to check raw
            p8_full_detail_on_error: deciding how to send output to llms WIP
            kwargs (the function call from a language model should be passed correct in context knowing the function spec
        """
        
        #endpoint, verb = self.openapi.get_endpoint_method(op_id)
        endpoint = function.endpoint
        f = getattr(requests, function.verb)
        """rewrite the url with the kwargs"""
        endpoint = endpoint.format_map(kwargs)
        endpoint = f"{self.uri}/{endpoint.lstrip('/')}"

        
        # if data is None: #callers dont necessarily know about data and may pass kwargs
        #     data = kwargs
        # if data and not isinstance(data,str):
        #     """support for passing pydantic models"""
        #     if hasattr(data, 'model_dump'):
        #         data = data.model_dump()
        #     data = json.dumps(data)

        headers = { } #"Content-type": "application/json"
        if self.token:
            headers["Authorization"] =  f"Bearer {self.token}"
        
        """f is verified - we just need the endpoint. data is optional, kwargs are used properly"""
        response = f(
            endpoint,
            headers=headers,
            params=kwargs,
            json=request_body,
        )

        try:
            response.raise_for_status()
            if p8_return_raw_response:
                return response
        
            """otherwise we try to be clever"""
            t = response.headers.get('Content-Type') or "text" #text assumed
            if 'json' in t:
                return  response.json()
            if t[:5] == 'image':
                from PIL import Image
                from io import BytesIO
                return Image.open(BytesIO(response.content))
            content = response.content
            return content.decode() if isinstance(content,bytes) else content
                        
            
        except Exception as ex:
            if not p8_full_detail_on_error:
                """raise so runner can do its thing"""
                raise Exception(json.dumps(response.json())) 
            return {
                "data": response.json(),
                "type": response.headers.get("Content-Type"),
                "status": response.status_code,
                "requested_endpoint": endpoint,
                "info": self.model_dump(),
                "exception" : repr(ex)
            }
