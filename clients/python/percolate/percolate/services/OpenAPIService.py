import yaml
import json
import os
import requests
from functools import partial
from percolate.models.p8 import Function

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
        return {
            'type' : schema.get('type'),
            'description': schema.get('description') or '' #empty descriptions can cause issues
        }
    return {
        'name': short_name or (spec.get('operationId') or spec.get('title')),
        'description': spec.get('description') or spec.get('summary'),
        'parameters' : {
            'type': 'object',
            'properties': {p['name']:_map(p['schema']) for p in (spec.get('parameters') or [])},
            'required': [p['name'] for p in spec.get('parameters') or [] if p.get('required')]
        } 
    }

    
class OpenApiSpec:
    """
    The spec object parses endpoints into function descriptions
    """
    def __init__(self, uri_or_spec: str| dict, token_key:str=None):
        """supply a spec object (dict) or a uri to one"""
        self._uri_str = ""
        if isinstance(uri_or_spec,str):
            self._uri_str = uri_or_spec
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
        self.token_key = token_key
        """lookup"""
        self._endpoint_methods = {op_id: (endpoint,method) for op_id, endpoint, method in self}
        self.short_names = self.map_short_names()
        
    def map_short_names(self):
        """in the context we assume a verb and endpoint is unique"""
        d = {}
        for k,v in self._endpoint_methods.items():
            endpoint, verb = v
            d[f"{verb}_{endpoint.lstrip('/').replace('/','_').replace('-','_').replace('{','').replace('}','')}"] = k
        return d
    
    def iterate_models(self):
        """yield the function models that can be saved to the database"""
        ep_to_short_names = {v:k for k,v in self.short_names.items()}
        for endpoint, grp in self.spec['paths'].items():
            for method, s in grp.items():
                op_id = s.get('operationId')
                fspec = map_openapi_to_function(s,short_name=ep_to_short_names[op_id])
                yield Function(name=ep_to_short_names[op_id],
                               key=op_id,
                               proxy_uri=self._uri_str,
                               spec = fspec,
                               verb=method,
                               endpoint=endpoint,
                               description=s.get('description'))
                    
        
    def __repr__(self):
        """
        """
        return f"OpenApiSpec({self._uri_str})"
    
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