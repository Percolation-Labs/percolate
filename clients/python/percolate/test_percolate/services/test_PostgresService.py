
import pytest
import percolate as p8
from pydantic import BaseModel,Field
from percolate.models import DefaultEmbeddingField

class MyFirstAgent(BaseModel):
    """You are an agent that provides the information you are asked and a second random fact"""
    #if it has no model config or python module it would save to the public database schema
    model_config = {'namespace':'public'}
    
    name: str = Field(description="Task name")
    #the default embedding field is just settings json_schema_extra.embedding_provider, so you can do that yourself
    description:str = DefaultEmbeddingField(description="Task description")
    
    @classmethod
    def get_model_functions(cls):
        """i return a list of functions by key stored in the database"""
        return {
            'get_pet_findByStatus': "a function i use to look up pets based on their status"
        }
        
@pytest.mark.slow
def test_register_model():
    """this test is used to test the creation of the test model"""
    repo = p8.repository(MyFirstAgent)
    _ = repo.register()
    
    """check if the model is registered
    1. The table must exist
    2. test that embedding was created when it should have been TODO:
    3. the graph view for watermark was created when it should have been
    """
    
    assert repo.check_entity_exists(), "The entity was not created at registration"
    
    
    
    
    
    