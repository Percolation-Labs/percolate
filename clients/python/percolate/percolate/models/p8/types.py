"""
all the table models are added here for p8 schema and can be iterated and used to generate install scripts
we add system fields in the sql model such as timestamps and user ids
"""

import uuid
from pydantic import Field, model_validator
from pydantic.fields import FieldInfo
import typing
from ..AbstractModel import AbstractModel, BaseModel, AbstractEntityModel
from .. import inspection
from percolate.utils import make_uuid
import datetime
from .. import DefaultEmbeddingField
from percolate.utils.names import EmbeddingProviders
class Function(AbstractEntityModel):
    """Functions are external tools that agents can use. See field comments for context.
    Functions can be searched and used as LLM tools. 
    The function spec is derived from OpenAPI but adapted to the conventional used in LLMs
    """
         
    id: uuid.UUID | str = Field(description="A unique id in this case generated by the proxy and function name") 
    key: typing.Optional[str] = Field(description='optional key e.g operation id')
    name: str = Field(description="A friendly name that is unique within the proxy scope e.g. a single api or python library")
    verb:  typing.Optional[str] = Field(None,description= "The verb e.g. get, post etc")
    endpoint: typing.Optional[str] = Field(None, description="A callable endpoint in the case of REST")
    description: str = DefaultEmbeddingField('', description="A detailed description of the function - may be more comprehensive than the one within the function spec - this is semantically searchable")
    function_spec: dict = Field(description="A function description that is OpenAI and based on the OpenAPI spec")
    proxy_uri: str = Field(description='a reference to an api or library namespace that qualifies the named function')
    
    
class LanguageModelApi(AbstractEntityModel):
    """The Language model REST Apis are stored with tokens and scheme information.
    """
    
    id: uuid.UUID | str
    name: str = Field(description="A unique name for the model api e.g cerebras-llama3.1-8b")
    model: typing.Optional[str] = Field(None, description="The model name defaults to the name as they are often the same. the name can be unique based on a provider qualfier")
    scheme: typing.Optional[str] = Field('openai', description="In practice most LLM APIs use an openai scheme - currently `anthropic` and `google` can differ")
    completions_uri: str = Field(description="The api used for completions in chat and function calling. There may be other uris for other contexts")
    token_env_key: typing.Optional[str] = Field(None, description="Conventions are used to resolve keys from env or other services. Provide an alternative key")
    token: typing.Optional[str] = Field(None, description="It is not recommended to add tokens directly to the data but for convenience you might want to")
    
        
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('model'):
            values['model'] = values['name']
        return values
        
    
class Agent(AbstractEntityModel):
    """The agent model is a meta data object to persist agent metadata for search etc"""

    id: uuid.UUID| str  
    name: str
    category: typing.Optional[str] = Field(None,description="Simple property to filter agents by categories")
    description: str = DefaultEmbeddingField(description="The system prompt as markdown")
    spec: dict = Field(description="The model json schema")
    functions: typing.Optional[dict] = Field(description="The function that agent can call",default_factory=dict)
    
    def from_abstract_model(cls: BaseModel):
        """Given any pydantic model that behaves like an AbstractModel, get the meta object i.e. Agent"""
        cls:AbstractModel = AbstractModel.Abstracted(cls)
        name = cls.get_model_full_name()
        return Agent(id=make_uuid(name), 
                     name=name, 
                     functions=cls.get_model_functions(),
                     spec = cls.model_json_schema(),
                     description=cls.get_model_description())

class ModelField(AbstractEntityModel):
    """Fields are each field in any saved model/agent. 
    Fields are useful for describing system info such as for embeddings or for promoting.
    """
            
    id: typing.Optional[uuid.UUID|str] = Field(description="a unique key for the field e.g. field and entity key hashed")
    name: str = Field(description="The field name")
    entity_name: str
    field_type: str
    embedding_provider: typing.Optional[str] = Field(None, description="The embedding could be a multiple in future")
    description: typing.Optional[str] = None
    is_key: bool = Field(default=False, description="Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings")
    
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        """this is a convenience for 'dont care' cases where you want an embedding but dont know the model name"""
        if values.get('embedding_provider') == 'default':
            values['embedding_provider'] = EmbeddingProviders.embedding_text_embedding_ada_002
        return values
    
    @classmethod
    def from_field_info(cls, key:str, field_type: FieldInfo, parent_model:BaseModel):
        """five a FieldInfo object map the field"""
        
        parent_model:AbstractModel = AbstractModel.Abstracted(parent_model)
        json_args = field_type.json_schema_extra or {}
        arg = inspection.get_innermost_args(field_type.annotation)
        arg = str(arg.__name__) if hasattr(arg, '__name__') else str(arg)
        return ModelField(name=key, 
                           entity_name= parent_model.get_model_full_name(), 
                           field_type= arg,
                           description=field_type.description,
                           **json_args)
        
    @staticmethod
    def get_fields_from_model(cls:BaseModel):
        """for any pydantic model generate the field collection"""
        cls = AbstractModel.Abstracted(cls)
        return [ModelField.from_field_info(key, value,parent_model=cls) for key, value in cls.model_fields.items()]
    
        
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = make_uuid({'name': values['name'], 'entity_name': values['entity_name']})
        return values

class TokenUsage(AbstractModel):
    """Tracks token usage for language model interactions"""
    id: uuid.UUID| str  
    model_name: str
    tokens: int = Field(description="the number of tokens consumed in total")
    tokens_in: typing.Optional[int] = Field(description="the number of tokens consumed for input")
    tokens_out: typing.Optional[int] = Field(description="the number of tokens consumed for output")
    tokens_other: typing.Optional[int] = Field(description="the number of tokens consumed for functions and other metadata")
    session_id: typing.Optional[uuid.UUID| str  ] = Field(description="Session id for a conversation")
    

class Dialogue(AbstractModel):
    """Each atom in an exchange between users, agents, assistants and so on"""
    id: uuid.UUID| str  
    model_name: str
    role: str = Field(description="The role of the user/agent in the conversation")
    content: str = DefaultEmbeddingField(description="The content for this part of the conversation")
    session_id: typing.Optional[uuid.UUID| str  ] = Field(description="Session id for a conversation")
    

class Session(AbstractModel):
    """Tracks groups if session dialogue"""
    id: uuid.UUID| str  
    description: typing.Optional[str] = Field(None,description='optional description for the session')

class ModelMatrix(AbstractModel):
    """keep useful json blobs for model info"""
    id: uuid.UUID| str  
    name: str = Field(description="The name of the entity e.g. a model in the types or a user defined model")
    enums: typing.Optional[dict] = Field(None, description="The enums used in the model - usually a job will build these and they can be used in query prompts")
    example_sql_queries: typing.Optional[dict] = Field(None, description="A mapping of interesting question to SQL queries - usually a job will build these and they can be used in query prompts")

class Project(AbstractEntityModel):
    """A project is a broadly defined goal with related resources (uses the graph)"""
    id: uuid.UUID| str  
    name: str = Field(description="The name of the entity e.g. a model in the types or a user defined model")
    description: str = DefaultEmbeddingField(description="The content for this part of the conversation")
    target_date: typing.Optional[datetime.datetime] = Field(None, description="Optional target date")
 
class Task(Project):
    """Tasks are sub projects. A project can describe a larger objective and be broken down into tasks"""
    id: uuid.UUID| str  
    project_name: typing.Optional[str] = Field(None, description="The related project name of relevant")
 
class User(AbstractEntityModel):
    """save user info"""
    id: uuid.UUID| str  
    name: str
    
class ContentIndex(AbstractModel):
    """Generic parsed content from files etc. added to the system"""
    id: typing.Optional[uuid.UUID| str] = Field("The id is generated as a hash of the required uri and ordinal")  
    name: typing.Optional[str] = Field(None, description="A short content name - non unique - for example a friendly label for a chunked pdf document")
    category: typing.Optional[str] = Field(None, description="A content category")
    content: str = DefaultEmbeddingField(description="The chunk of content from the source")
    ordinal: int = Field(None, description="For chunked content we can keep an ordinal")
    uri: str = Field("An external source or content ref e.g. a PDF file on blob storage or public URI")
    
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = make_uuid({'uri': values['uri'], 'ordinal': values['ordinal']})
        return values