import yaml
import json
import os
import requests
from functools import partial
from percolate.models.p8 import Function
import typing
from percolate.utils import logger


def map_openapi_to_function(spec,short_name:str=None):
    """Map an OpenAPI endpoint spec to a function ala open AI
       you can add functions from this to the tool format with for example
       
       ```python
       fns = [map_openai_to_function(openpi_spec_json['/weather']['get'])]
       tools = [{'type': 'function', 'function': f} for f in fns]
       ```
    """
    def _map(schema):
        """map the parameters containing schema to a flatter rep"""
        if 'schema' in schema:
            schema = schema['schema']
        
        type = schema.get('type')
        enums = None
        """check for array types"""
        if 'items' in schema:
            if 'enum' in schema['items']:
                enums = schema['items']['enum']
        if 'enum' in schema:
            enums = schema['enums']
        d = {
            'type' : type,
            'description': schema.get('description') or '' #empty descriptions can cause issues
        }
        if enums:
            d['enum'] = enums
        return d
        
    try:
        r =  {
            'name': short_name or (spec.get('operationId') or spec.get('title')),
            'description': spec.get('description') or spec.get('summary'),
            'parameters' : {
                'type': 'object',
                'properties': {p['name']:_map(p) for p in (spec.get('parameters') or [])},
                'required': [p['name'] for p in spec.get('parameters') or [] if p.get('required')]
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
    def __init__(self, uri_or_spec: str| dict, token_key:str=None):
        """supply a spec object (dict) or a uri to one"""
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
            self.host_uri = f"https://{self.spec['host']}"
            if 'basePath' in self.spec:
                self.host_uri += self.spec['basePath']
        else:
            """by convention we assume the uri is the path without the json file"""
            self.host_uri = self._spec_uri_str.rsplit('/', 1)[0]

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
        for endpoint, grp in self.spec['paths'].items():
            for method, s in grp.items():
                op_id = s.get('operationId')
                if verbs and method not in verbs:
                    continue
                if filter_ops and op_id not in filter_ops:
                    continue
                fspec = map_openapi_to_function(s,short_name=ep_to_short_names[op_id])
                yield Function(name=ep_to_short_names[op_id],
                               key=op_id,
                               proxy_uri=self.host_uri,
                               function_spec = fspec,
                               verb=method,
                               endpoint=endpoint,
                               description=s.get('description'))
                    
        
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

        return {"parameters": parameters, "request_body": request_body}
    
    
class OpenApiService:
    def __init__(self, uri, token_or_key:str=None, spec: OpenApiSpec=None):
        """a wrapper to invoke functions"""
        
        self.uri = uri
        self.spec = spec
        """assume token but maybe support mapping from env"""
        self.token_or_key = token_or_key
        
    def invoke(self, function:Function, data:dict=None, p8_return_raw_response:bool=False, p8_full_detail_on_error: bool = False, **kwargs):
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

        if data is None: #callers dont necessarily know about data and may pass kwargs
            data = kwargs
        if data and not isinstance(data,str):
            """support for passing pydantic models"""
            if hasattr(data, 'model_dump'):
                data = data.model_dump()
            data = json.dumps(data)

        headers = { } #"Content-type": "application/json"
        if self.token_or_key:
            headers["Authorization"] =  f"Bearer {os.environ.get(self.token_key)}"
        
        """f is verified - we just need the endpoint. data is optional, kwargs are used properly"""
        response = f(
            endpoint,
            headers=headers,
            params=kwargs,
            data=data,
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
