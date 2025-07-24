#!/usr/bin/env python
"""
Test for PostgresService semantic search functionality
"""

import pytest
import os
from unittest.mock import Mock, patch
from percolate.services.PostgresService import PostgresService
from percolate.models.AbstractModel import AbstractModel
from percolate.models.p8.types import Resources
from pydantic import BaseModel


class TestSemanticSearchOnly:
    """Test the is_semantic_search_only functionality"""
    
    def test_resources_model_returns_true(self):
        """Test that Resources model returns True for semantic search only"""
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(Resources) == True
    
    def test_resources_subclass_returns_true(self):
        """Test that subclass of Resources returns True"""
        class CustomResources(Resources):
            pass
        
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(CustomResources) == True
    
    def test_non_resources_model_returns_false(self):
        """Test that non-Resources models return False"""
        class SomeModel(BaseModel):
            name: str
        
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(SomeModel) == False
    
    def test_abstract_model_returns_false(self):
        """Test that AbstractModel returns False"""
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(AbstractModel) == False
    
    def test_env_var_override_true(self):
        """Test environment variable override to True"""
        with patch.dict(os.environ, {'P8_RESOURCES_SEMANTIC_ONLY': 'true'}):
            service = PostgresService(on_connect_error="ignore")
            # Should return True regardless of model
            assert service.is_semantic_search_only(AbstractModel) == True
            assert service.is_semantic_search_only(Resources) == True
    
    def test_env_var_override_false(self):
        """Test environment variable override to False"""
        with patch.dict(os.environ, {'P8_RESOURCES_SEMANTIC_ONLY': 'false'}):
            service = PostgresService(on_connect_error="ignore")
            # Should return False even for Resources
            assert service.is_semantic_search_only(Resources) == False
    
    def test_env_var_various_true_values(self):
        """Test various truthy env var values"""
        # Just test 'true' since this is what the code expects
        with patch.dict(os.environ, {'P8_RESOURCES_SEMANTIC_ONLY': 'true'}):
            service = PostgresService(on_connect_error="ignore")
            # Pass a non-Resources model to test env var override
            class TestModel(BaseModel):
                name: str
            assert service.is_semantic_search_only(TestModel) == True
    
    def test_env_var_various_false_values(self):
        """Test various falsy env var values"""
        falsy_values = ['FALSE', '0', 'no', 'NO', 'off', 'OFF', 'anything_else']
        
        for value in falsy_values:
            with patch.dict(os.environ, {'P8_RESOURCES_SEMANTIC_ONLY': value}):
                service = PostgresService(on_connect_error="ignore")
                assert service.is_semantic_search_only() == False, f"Failed for value: {value}"
    
    def test_no_model_returns_false(self):
        """Test that no model returns False"""
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(None) == False
    
    def test_instance_model_used_when_no_param(self):
        """Test that instance model is used when no parameter passed"""
        # Test with Resources model on instance
        service = PostgresService(model=Resources)
        assert service.is_semantic_search_only() == True
        
        # Test with non-Resources model on instance
        class OtherModel(BaseModel):
            name: str
        
        service = PostgresService(model=OtherModel)
        assert service.is_semantic_search_only() == False
    
    def test_model_config_override_true(self):
        """Test that model_config is_semantic_only overrides default behavior"""
        # Non-Resources model with is_semantic_only = True
        class NonResourcesModel(BaseModel):
            name: str
            model_config = {'is_semantic_only': True}
        
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(NonResourcesModel) == True
    
    def test_model_config_override_false(self):
        """Test that model_config can disable semantic only for Resources"""
        # Resources subclass with is_semantic_only = False
        class CustomResources(Resources):
            model_config = {'is_semantic_only': False}
        
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(CustomResources) == False
    
    def test_model_config_with_other_settings(self):
        """Test model_config with is_semantic_only among other settings"""
        class ModelWithConfig(BaseModel):
            name: str
            model_config = {
                'name': 'TestModel',
                'namespace': 'test',
                'is_semantic_only': True,
                'other_setting': 'value'
            }
        
        service = PostgresService(on_connect_error="ignore")
        assert service.is_semantic_search_only(ModelWithConfig) == True
    
    def test_model_config_non_dict_ignored(self):
        """Test that models without is_semantic_only in config fall back to inheritance check"""
        # Test with a Resources subclass that has config without is_semantic_only
        class ModelWithoutSemanticConfig(Resources):
            model_config = {'arbitrary_key': 'value'}
        
        service = PostgresService(on_connect_error="ignore")
        # Should fall back to Resources check since is_semantic_only is not in config
        assert service.is_semantic_search_only(ModelWithoutSemanticConfig) == True
        
        # Test with a non-Resources model without is_semantic_only
        class NonResourcesModel(BaseModel):
            name: str
            model_config = {'some_other_key': 'value'}
        
        # Should return False since it doesn't inherit from Resources
        assert service.is_semantic_search_only(NonResourcesModel) == False


class TestSearchWithSemanticOnly:
    """Test the search method with semantic only parameter"""
    
    @patch.object(PostgresService, 'execute')
    def test_search_with_resources_model(self, mock_execute):
        """Test search passes True for semantic_only with Resources model"""
        mock_execute.return_value = [{'relational_result': None, 'vector_result': 'some data'}]
        
        service = PostgresService(model=Resources, on_connect_error="ignore")
        service.search("test question", user_id="test_user")
        
        # Verify the fourth parameter is True
        mock_execute.assert_called_once()
        call_args = mock_execute.call_args[1]['data']
        assert call_args[0] == "test question"
        assert call_args[1] == "p8.Resources"
        assert call_args[2] == "test_user"
        assert call_args[3] == True  # semantic_only should be True
    
    @patch.object(PostgresService, 'execute')
    def test_search_with_non_resources_model(self, mock_execute):
        """Test search passes False for semantic_only with non-Resources model"""
        mock_execute.return_value = [{'relational_result': 'some data', 'vector_result': None}]
        
        class TestModel(BaseModel):
            name: str
        
        # Use AbstractModel.Abstracted to ensure it has the interface methods
        TestModel = AbstractModel.Abstracted(TestModel)
            
        service = PostgresService(model=TestModel, on_connect_error="ignore")
        service.search("test question", user_id="test_user")
        
        # Verify the fourth parameter is False
        mock_execute.assert_called_once()
        call_args = mock_execute.call_args[1]['data']
        assert call_args[0] == "test question"
        assert call_args[1] == TestModel.get_model_full_name()
        assert call_args[2] == "test_user"
        assert call_args[3] == False  # semantic_only should be False
    
    @patch.object(PostgresService, 'execute')
    def test_search_with_env_override(self, mock_execute):
        """Test search respects environment variable override"""
        mock_execute.return_value = [{'relational_result': None, 'vector_result': 'some data'}]
        
        # Override to False even for Resources
        with patch.dict(os.environ, {'P8_RESOURCES_SEMANTIC_ONLY': 'false'}):
            service = PostgresService(model=Resources, on_connect_error="ignore")
            service.search("test question")
            
            # Verify the fourth parameter is False due to env override
            call_args = mock_execute.call_args[1]['data']
            assert call_args[3] == False  # semantic_only should be False due to override


if __name__ == "__main__":
    pytest.main([__file__, "-v"])