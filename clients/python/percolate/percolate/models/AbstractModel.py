"""Abstract Model and Mixins are used for declarative metadata in Percolate"""

from pydantic import BaseModel, Field, create_model,ConfigDict
from . import inspection
from abc import ABC
import typing
import docstring_parser
import inspect
import types
from percolate.utils.env import P8_EMBEDDINGS_SCHEMA
from .utils import SqlModelHelper
from pydantic._internal._model_construction import ModelMetaclass
from .MessageStack import MessageStack

def ensure_model_not_instance(cls_or_instance: typing.Any):
    if not isinstance(cls_or_instance, ModelMetaclass) and isinstance(
        cls_or_instance, BaseModel
    ):
        """because of its its convenient to use an instance to construct stores and we help the user"""
        return cls_or_instance.__class__
    return cls_or_instance
    
    """this will be a stack of messages with some useful things"""

class AbstractModelMixin:
    """adds declarative metadata scraping from objects"""
    
    @classmethod
    def get_model_name(cls)->str:
        """the unqualified model name"""
        c:ConfigDict = cls.model_config 
        return c.get('name') or cls.__name__
    
    @classmethod
    def get_model_namespace(cls)->str:
        """the namespace provided by config or convention"""
        c:ConfigDict = cls.model_config 
        return c.get('namespace') or inspection.object_namespace(cls)
    
    @classmethod
    def get_model_key_field(cls)->str:
        """this is used to provide a business key from which we can generate a unique id.
        The BaseModel can have and id in which case we return null and use that id
        Otherwise we look for the is_key attribute.
        Otherwise we try key or name properties assuming them to be unique
        Best practice is for the model to provide its own id and not rely on key inference
        """
        s = cls.model_json_schema(by_alias=False)
        
        if 'properties' not in s and '$defs' in s:
            """for nested complex types get the schema"""
            if cls.get_model_name() in s['$defs']:
                s = s['$defs'][cls.get_model_name()]
        
        key_props = [k for k, v in s["properties"].items() if v.get("is_key") or v.get('primary_key')]
        if len(key_props):
            return key_props[0]
        """convention is to look for a key or name"""
        f = cls.model_fields
        if 'name' in f:
            return 'name'
        if 'key' in f:
            return 'key'
            
    @classmethod
    def get_model_functions(cls) ->dict:
        c:ConfigDict = cls.model_config 
        return c.get('functions')
    
    @classmethod
    def get_model_full_name(cls)->str:
        """fully qualified namespace.name"""
        return f"{cls.get_model_namespace()}.{cls.get_model_name()}"
    
    @classmethod
    def get_model_table_name(cls)->str:
        """table name quotes casing for postgres e.g public."Table" """
        return f'{cls.get_model_namespace()}."{cls.get_model_name()}"'
    
    @classmethod
    def get_model_embedding_table_name(cls)->str:
        """table name quotes casing for postgres e.g public."Table" """
        return f'{P8_EMBEDDINGS_SCHEMA}."{cls.get_model_namespace()}_{cls.get_model_name()}_embeddings"'
    
    @classmethod
    def get_model_description(cls,use_full_description:bool=True)->str:
        """the doc string of the object is typically the model system prompt. Config can also be used to set description"""
        c:ConfigDict = cls.model_config 
        desc =  c.get('description') or cls.__doc__  
        desc =  desc or cls.get_model_full_name()
        
        if use_full_description:
            schema = cls.model_json_schema()
            desc = f"""# Agent - {cls.get_model_full_name()}\n{desc}\n# Schema\n\n```{schema}``` \n\n# Functions\n ```\n{cls.get_model_functions()}```
            """
        return desc
    
    @classmethod
    def model_parse(cls, values: dict) -> "AbstractModel":
        """try to parse even when the dict objects are dumped json"""
        import json
        for k, v in cls.model_fields.items():
            t = inspection.get_innermost_args(v.annotation)
            if t == dict or inspection.match_type(t, BaseModel):
                try:
                    if isinstance(values[k], str):
                        values[k] = json.loads(values[k])
                except Exception as ex:
                    pass
        return cls(**values)
    
    @classmethod
    def _on_load(cls):
        """this can be called by models to inject custom data into agent prompt
        if overridden in python, anything can be used as a loader.
        if a query is defined in the database, it will be run here 
        """
        
        if hasattr(cls, 'model_config') and  cls.model_config.get( 'on_load_query'):
            """assume a query - we could also support a function in future"""
            query = cls.model_config['on_load_query']
            from percolate.services import PostgresService
            from percolate.utils import logger
            logger.debug(f"Onload model prompt - running {query=}")
            pg = PostgresService()
            return {
                'on_load_query': query,
                'on_load_data':
                pg.execute(query)
            }
        
        if hasattr(cls, 'model_config') and cls.model_config.get( 'on_load_function'):
             raise NotImplementedError("We have not implemented the case of loading functions on load")
        return None
    
    @classmethod
    def build_message_stack(cls, question:str, data: typing.List[dict] = None, user_memory=None, **kwargs) -> MessageStack | typing.List[dict ]:
        """Generate a message stack using a list of messages.
        These messages are in the list of content/role generalized LLM messages.
        This is added here so that BaseModel's can override but by default we just use the MessageStack utility
        """
        
        """if the data can be loaded from the agent we do it here but only if data are not overridden"""
        data = data or cls._on_load()
        
        return MessageStack.build_message_stack(cls, question, data=data,user_memory=user_memory, **kwargs)

    @classmethod
    def to_sql_model_helper(cls):
        """
        Return the Sql Model Helper for generating SQL from pydantic models
        """
        return SqlModelHelper(cls)
    
    
    @classmethod
    def to_arrow_schema(cls):
        """get the arrow schema for the pydantic model with some conventions"""
    
    @classmethod
    def to_arrow_schema(cls):
        """
        get the arrow schema from the pydantic type
        """
        from percolate.utils.types.pydantic import pydantic_to_arrow_schema

        return pydantic_to_arrow_schema(
            cls
        )
    
    @classmethod
    def fields_from_json_schema(cls, json_schema: dict) -> typing.Dict[str, typing.Tuple[typing.Any, Field]]:
        """
        Convert a JSON Schema to Pydantic field definitions
        
        Args:
            json_schema: Standard JSON Schema dict
            
        Returns:
            Dict mapping field names to (type, Field) tuples for create_model
        """
        from percolate.utils.types.pydantic import JsonSchemaConverter
        
        return JsonSchemaConverter.fields_from_json_schema(json_schema, parent_model=cls)
    
class AbstractModel(BaseModel, ABC, AbstractModelMixin):
    """Percolate's abstract model type with mixing methods"""
    
    @classmethod
    def create_model_from_function(
        cls, fn: typing.Callable, name_prefix: str = None
    ) -> "AbstractModel":
        """
        Create a model from any python function - used for JsonSchema of functions
        
        Args:
            fn: any callable function but should have typing info
            name_prefix: an optional qualified for generating the function schema name
        """

        def s_combine(*l): return "\n".join(i for i in l if i)

        """parse the docstring"""
        p = docstring_parser.parse(fn.__doc__)
        description = s_combine(p.short_description, p.long_description)
        parameter_descriptions = {p.arg_name: p.description for p in p.params}
        
        """make fields from typing and docstring"""
        signature = inspect.signature(fn)
        type_hints = typing.get_type_hints(fn)
        fields = {}
        for name, param in signature.parameters.items():
            if name == "self":
                continue
            """things like kwargs that have no type will not be added to the model for the function"""
            annotation = type_hints.get(name, None)
            default = (
                param.default if param.default is not inspect.Parameter.empty else ...
            )
            """add the desc from the doc sting args when creating the field"""
            field = Field(default=default, description=parameter_descriptions.get(name))
      
            if annotation:
                fields[name] = (annotation, field)

        """create the function model"""
        name = fn.__name__ if not name_prefix else f"{name_prefix}_{fn.__name__}"
        return create_model(fn.__name__, __doc__=description, **fields)


    @classmethod
    def create_model(
        cls,
        name: str,
        namespace: str = None,
        description: str = None,
        functions: dict = None,
        fields=None,
        access_level=None,
        inherit_config: bool = True,
        **kwargs,
    ):
        """
        For dynamic creation of models for the type systems
        create a model that inherits from the cls and add any extra fields

        Args:
            name: name of the model (only required prop)
            namespace: namespace for the model - types take python models or we can use public as default
            description: a markdown description of the model e.g. system prompt
            functions: a map of function ids and how they are to be used on context
            access_level: access level for row-level security (AccessLevel enum or int)
            inherit_config: whether to inherit parent model config (default: True)
            **kwargs: additional config parameters to merge
        """
        if not fields:
            fields = {}
        namespace = namespace or cls.get_model_namespace()
        model = create_model(name, **fields, __module__=namespace, __base__=cls)
        
        # Start with base config
        base_config = {
            'name': name,
            'namespace': namespace,
            'description': description,
            'functions': functions,
        }
        
        # If inherit_config is True, inherit parent's model_config
        if inherit_config and hasattr(cls, 'model_config'):
            # Get parent config
            parent_config = getattr(cls, 'model_config', {})
            if isinstance(parent_config, dict):
                # Start with parent config as base
                model_config = parent_config.copy()
                # Update with new values (upsert)
                model_config.update(base_config)
            else:
                # If parent config is not a dict, just use base config
                model_config = base_config
        else:
            # No inheritance, just use base config
            model_config = base_config
        
        # Add access_level if provided
        if access_level is not None:
            # Handle both enum and int values
            if hasattr(access_level, 'value'):
                model_config['access_level'] = access_level.value
            else:
                model_config['access_level'] = access_level
        
        # Merge any additional kwargs into config
        for key, value in kwargs.items():
            if key not in ['fields', '__module__', '__base__']:  # Skip special args
                model_config[key] = value
        
        # Set the final config on the model
        model.model_config = model_config
        
        return model

    def Abstracted(model: BaseModel)->BaseModel:
        """
        Mixin for any base model instance. If an instance is passed we modify to the type e.g. Instance of Base Model -> type(BaseModel)
        The class can implement the interface i.e. we do not add methods if they are on the pydantic object.
        Otherwise we add methods that inspect or infer declarative properties of the model
        """
        if isinstance(model, AbstractModel):
            return model
        
        model = ensure_model_not_instance(model)
         
        for  method in inspection.get_class_and_instance_methods(AbstractModelMixin):
            """only add if we are not replacing"""
            if not hasattr(model, method.__name__):
                if isinstance(method, classmethod):
                    # Rebind the classmethod by wrapping it for SampleModel
                    bound_method = classmethod(method.__func__.__get__(model, model))
                    setattr(model, method.__name__, bound_method)
                
                else:
                    # For instance methods, bind them to the SampleModel directly
                    bound_method = types.MethodType(method.__func__, model)
                    setattr(model, method.__name__, bound_method)

        return model
    
class AbstractEntityModel(AbstractModel):
    name: str = Field("A unique name for the entity")