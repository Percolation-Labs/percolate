"""Test try_load_model function with database loading"""
import pytest
from unittest.mock import Mock, patch, MagicMock
from percolate.interface import try_load_model
from percolate.models.AbstractModel import AbstractModel
from percolate.models.p8 import types as p8_types
import uuid

@pytest.mark.slow
class TestTryLoadModel:
    """Test try_load_model function with all loading methods"""
    
    @patch('percolate.interface.custom_load_model')
    def test_custom_loader_first(self, mock_custom_load):
        """Test that custom loader is tried first"""
        mock_model = Mock()
        mock_model.get_model_name.return_value = "CustomModel"
        mock_custom_load.return_value = mock_model
        
        result = try_load_model("test.Model")
        
        assert result == mock_model
        mock_custom_load.assert_called_once_with("test.Model")
    
    def test_database_loader_integration(self):
        """Test database loading with real Agent._create_model_from_data"""
        # This tests the actual integration without mocking the import
        from percolate.models.p8.types import Agent
        
        # Create test data
        agent_data = {
            'name': 'test.DatabaseModel',
            'id': str(uuid.uuid4()),
            'spec': {
                'type': 'object',
                'properties': {
                    'name': {'type': 'string', 'description': 'Name field'},
                    'value': {'type': 'integer', 'default': 0}
                },
                'required': ['name']
            },
            'functions': {'test_func': {'description': 'Test function'}},
            'metadata': {'source': 'test'}
        }
        
        # Create model using real method
        model = Agent._create_model_from_data(agent_data)
        
        # Mock the Agent.load to return our model
        with patch.object(Agent, 'load', return_value=model):
            with patch('percolate.interface.custom_load_model', return_value=None):
                result = try_load_model("test.DatabaseModel")
        
        assert result is not None
        assert result.get_model_full_name() == "test.DatabaseModel"
        assert result.model_config['source'] == 'test'
        assert result.model_config['functions']['test_func']['description'] == 'Test function'
    
    @patch('percolate.interface.custom_load_model')
    @patch('percolate.interface.load_model')
    def test_code_loader_fallback(self, mock_load_model, mock_custom_load):
        """Test that code loader is used when database load fails"""
        mock_custom_load.return_value = None
        
        # Create a mock model from code
        mock_model = Mock()
        mock_model.get_model_name.return_value = "CodeModel"
        mock_load_model.return_value = mock_model
        
        # Mock Agent.load to fail
        with patch.object(p8_types.Agent, 'load', side_effect=ValueError("Not in database")):
            result = try_load_model("test.CodeModel")
        
        assert result == mock_model
        mock_load_model.assert_called_once_with("test.CodeModel")
    
    @patch('percolate.interface.custom_load_model', return_value=None)
    @patch('percolate.interface.load_model', side_effect=ImportError("Not found"))
    def test_abstract_model_creation(self, mock_load_model, mock_custom_load):
        """Test abstract model creation when all other methods fail"""
        # Mock Agent.load to fail
        with patch.object(p8_types.Agent, 'load', side_effect=ValueError("Not in database")):
            # Test with namespace
            result = try_load_model("custom.namespace.Model", allow_abstract=True)
            assert result is not None
            assert issubclass(result, AbstractModel)
            assert result.get_model_name() == "namespace.Model"
            assert result.get_model_namespace() == "custom"
            
            # Test without namespace
            result = try_load_model("SimpleModel", allow_abstract=True)
            assert result is not None
            assert result.get_model_name() == "SimpleModel"
            assert result.get_model_namespace() == "public"
    
    @patch('percolate.interface.custom_load_model', return_value=None)
    @patch('percolate.interface.load_model', side_effect=ImportError("Not found"))
    def test_returns_none_when_not_allowed_abstract(self, mock_load_model, mock_custom_load):
        """Test returns None when abstract not allowed and all methods fail"""
        with patch.object(p8_types.Agent, 'load', side_effect=ValueError("Not in database")):
            result = try_load_model("test.Model", allow_abstract=False)
            assert result is None
    
    def test_loading_order_priority(self):
        """Test that loading methods are tried in correct order"""
        call_order = []
        
        # Mock all loaders to track call order
        def mock_custom(name):
            call_order.append('custom')
            return None
        
        def mock_db_load(name):
            call_order.append('database')
            raise ValueError("Not found")
        
        def mock_code_load(name):
            call_order.append('code')
            raise ImportError("Not found")
        
        with patch('percolate.interface.custom_load_model', side_effect=mock_custom):
            with patch.object(p8_types.Agent, 'load', side_effect=mock_db_load):
                with patch('percolate.interface.load_model', side_effect=mock_code_load):
                    result = try_load_model("test.Model", allow_abstract=True)
        
        # Verify order
        assert call_order == ['custom', 'database', 'code']
        assert result is not None  # Abstract model created
        assert issubclass(result, AbstractModel)
    
    @patch('percolate.interface.CUSTOM_PROVIDER', {'data': None})
    def test_skips_custom_when_not_configured(self):
        """Test skips custom loader when provider is None"""
        # This should go directly to database loader
        with patch.object(p8_types.Agent, 'load') as mock_agent_load:
            mock_model = Mock()
            mock_agent_load.return_value = mock_model
            
            result = try_load_model("test.Model")
            
            assert result == mock_model
            mock_agent_load.assert_called_once_with("test.Model")