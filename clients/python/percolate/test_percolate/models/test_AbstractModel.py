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