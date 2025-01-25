import pytest
from pydantic import BaseModel, Field
from percolate.models import AbstractModel
from percolate.models.AbstractModel import AbstractModelMixin
import uuid
from percolate.utils import make_uuid
import typing


class SampleModel(BaseModel):
    """This is a description"""
    model_config = { 'namespace': "test" }
    id: uuid.UUID | str
    description: str = Field(description="The field description", json_schema_extra={'embedding_provider': 'default'})
    metadata: typing.Optional[dict] = Field(default_factory=dict,description="The object metadata")
    
    
    
def test_abstract_model_Abstracts():
    print(AbstractModelMixin.__dict__.items())
    model = SampleModel(
        id = make_uuid('test'), name='test', description='test description'
    )
    s:AbstractModel = AbstractModel.Abstracted(model)
    
    assert s.get_model_description() == 'This is a description', "Failed to retrieve desc from docstring on object on instance"
    assert s.get_model_functions() == None, "Unable to call for empty func on instance"
    assert s.get_model_name() == 'SampleModel', "The model name was not retrieved from the instance on instance"
    assert s.get_model_namespace() == 'test', "the test namespace was not fetched from the config on instance"
    assert s.get_model_table_name() == 'test."SampleModel"', "the table name is not properly formatted on instance"
    
    s:AbstractModel = AbstractModel.Abstracted(SampleModel)
    assert s.get_model_description() == 'This is a description', "Failed to retrieve desc from docstring on object on type"
    assert s.get_model_functions() == None, "Unable to call for empty func  on instance on type"
    assert s.get_model_name() == 'SampleModel', "The model name was not retrieved from the instance  on instance on type"
    assert s.get_model_namespace() == 'test', "the test namespace was not fetched from the config  on instance on type"
    assert s.get_model_table_name() == 'test."SampleModel"', "the table name is not properly formatted on type"
    
    
def test_models_carry_module_namespace():
    from percolate.models.p8 import Task
    assert Task.get_model_full_name() == 'p8.Task', "The modules in the namespace import from types should be in the p8 namespace"
    
    
def test_construction():
    from percolate.models.p8 import LanguageModelApi
    from percolate.utils import make_uuid
    models = [
        LanguageModelApi(id = make_uuid('gpt-4o-mini'), name = 'gpt-4o-mini', scheme='openai', completions_uri='https://api.openai.com/v1/chat/completions', token_env_key='OPENAI_API_KEY', token=None),
        LanguageModelApi(id = make_uuid('cerebras-llama3.1-8b'), name = 'cerebras-llama3.1-8b', model='llama3.1-8b', scheme='openai', completions_uri='https://api.cerebras.ai/v1/chat/completions', token_env_key='CEREBRAS_API_KEY'),
        LanguageModelApi(id = make_uuid('groq-llama-3.3-70b-versatile'), name = 'groq-llama-3.3-70b-versatile', model='llama-3.3-70b-versatile', scheme='openai', completions_uri='https://api.groq.com/openai/v1/chat/completions', token_env_key='GROQ_API_KEY'),
        LanguageModelApi(id = make_uuid('claude-3-5-sonnet-20241022'), name = 'claude-3-5-sonnet-20241022', scheme='anthropic', completions_uri='https://api.anthropic.com/v1/messages', token_env_key='ANTHROPIC_API_KEY'),
        LanguageModelApi(id = make_uuid('gemini-1.5-flash'), name = 'gemini-1.5-flash', scheme='google', completions_uri='https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent', token_env_key='GEMINI_API_KEY'),
        LanguageModelApi(id = make_uuid('deepseek-chat'), name = 'deepseek-chat', scheme='openai', completions_uri='https://api.deepseek.com/chat/completions', token_env_key='DEEPSEEK_API_KEY'),
    ]
