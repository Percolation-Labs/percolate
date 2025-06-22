import pytest
from unittest.mock import Mock, patch
from percolate.models.p8.types import Agent
from percolate.models.AbstractModel import AbstractModel
from datetime import datetime
import uuid


class TestAgentLoad:
    """Test Agent.load() functionality"""
    
    @patch('percolate.repository')
    def test_load_agent_with_exact_example_data(self, mock_repository):
        """Test loading agent with the exact example data provided"""
        # Exact data from the example
        agent_data = {
            'name': 'p8.Project',
            'id': '3d291419-02cd-58b4-a96e-76aadee594c3',
            'category': None,
            'description': "# Agent - p8.Project\nA project is a broadly defined goal with related resources (uses the graph)\n# Schema\n\n```{''description'': ''A project is a broadly defined goal with related resources (uses the graph)'', ''properties'': {''name'': {''description'': ''The name of the entity e.g. a model in the types or a user defined model'', ''title'': ''Name'', ''type'': ''string''}, ''id'': {''anyOf'': [{''format'': ''uuid'', ''type'': ''string''}, {''type'': ''string''}], ''title'': ''Id''}, ''description'': {''description'': ''The content for this part of the conversation'', ''embedding_provider'': ''default'', ''title'': ''Description'', ''type'': ''string''}, ''target_date'': {''anyOf'': [{''format'': ''date-time'', ''type'': ''string''}, {''type'': ''null''}], ''default'': None, ''description'': ''Optional target date'', ''title'': ''Target Date''}, ''collaborator_ids'': {''description'': ''Users collaborating on this project'', ''items'': {''format'': ''uuid'', ''type'': ''string''}, ''title'': ''Collaborator Ids'', ''type'': ''array''}, ''status'': {''anyOf'': [{''type'': ''string''}, {''type'': ''null''}], ''default'': ''active'', ''description'': ''Project status'', ''title'': ''Status''}, ''priority'': {''anyOf'': [{''type'': ''integer''}, {''type'': ''null''}], ''default'': 1, ''description'': ''Priority level (1-5), 1 being the highest priority'', ''title'': ''Priority''}}, ''required'': [''name'', ''id'', ''description''], ''title'': ''Project'', ''type'': ''object''}``` \n\n# Functions\n ```\nNone```\n            ",
            'spec': {
                'description': 'A project is a broadly defined goal with related resources (uses the graph)',
                'properties': {
                    'name': {
                        'description': 'The name of the entity e.g. a model in the types or a user defined model',
                        'title': 'Name',
                        'type': 'string'
                    },
                    'id': {
                        'anyOf': [{'format': 'uuid', 'type': 'string'}, {'type': 'string'}],
                        'title': 'Id'
                    },
                    'description': {
                        'description': 'The content for this part of the conversation',
                        'embedding_provider': 'default',
                        'title': 'Description',
                        'type': 'string'
                    },
                    'target_date': {
                        'anyOf': [{'format': 'date-time', 'type': 'string'}, {'type': 'null'}],
                        'default': None,
                        'description': 'Optional target date',
                        'title': 'Target Date'
                    },
                    'collaborator_ids': {
                        'description': 'Users collaborating on this project',
                        'items': {'format': 'uuid', 'type': 'string'},
                        'title': 'Collaborator Ids',
                        'type': 'array'
                    },
                    'status': {
                        'anyOf': [{'type': 'string'}, {'type': 'null'}],
                        'default': 'active',
                        'description': 'Project status',
                        'title': 'Status'
                    },
                    'priority': {
                        'anyOf': [{'type': 'integer'}, {'type': 'null'}],
                        'default': 1,
                        'description': 'Priority level (1-5), 1 being the highest priority',
                        'title': 'Priority'
                    }
                },
                'required': ['name', 'id', 'description'],
                'title': 'Project',
                'type': 'object'
            },
            'functions': None,
            'metadata': {'test': 'value'}
        }
        
        # Setup mock repository
        mock_repo = Mock()
        mock_repo.select.return_value = [agent_data]
        mock_repository.return_value = mock_repo
        
        # Load the agent
        loaded_model = Agent.load('p8.Project')
        
        # Verify repository was called correctly
        mock_repo.select.assert_called_once_with(name='p8.Project')
        
        # Verify the loaded model
        assert loaded_model.get_model_name() == 'Project'
        assert loaded_model.get_model_namespace() == 'p8'
        assert loaded_model.get_model_full_name() == 'p8.Project'
        
        # Check model_config
        assert hasattr(loaded_model, 'model_config')
        assert loaded_model.model_config['name'] == 'Project'
        assert loaded_model.model_config['namespace'] == 'p8'
        assert loaded_model.model_config['description'] == agent_data['description']
        assert loaded_model.model_config['functions'] is None
        assert loaded_model.model_config['test'] == 'value'  # Metadata was merged
        assert loaded_model.model_config['agent_id'] == '3d291419-02cd-58b4-a96e-76aadee594c3'
        
        # Test creating an instance
        instance = loaded_model(
            name="Test Project",
            id="test-id-123",
            description="A test project description"
        )
        assert instance.name == "Test Project"
        assert instance.id == "test-id-123"
        assert instance.description == "A test project description"
        assert instance.status == "active"  # Default value
        assert instance.priority == 1  # Default value
        
        # Test optional fields
        instance_with_optionals = loaded_model(
            name="Advanced Project",
            id=str(uuid.uuid4()),
            description="An advanced project",
            target_date=datetime.now(),
            collaborator_ids=[str(uuid.uuid4()), str(uuid.uuid4())],
            status="in_progress",
            priority=2
        )
        assert instance_with_optionals.status == "in_progress"
        assert instance_with_optionals.priority == 2
        assert len(instance_with_optionals.collaborator_ids) == 2
    
    @patch('percolate.repository')
    def test_load_agent_not_found(self, mock_repository):
        """Test loading non-existent agent"""
        mock_repo = Mock()
        mock_repo.select.return_value = []
        mock_repository.return_value = mock_repo
        
        with pytest.raises(ValueError, match="Agent 'NonExistent' not found in database"):
            Agent.load('NonExistent')
    
    @patch('percolate.repository')
    def test_load_agent_multiple_found(self, mock_repository):
        """Test loading when multiple agents match"""
        mock_repo = Mock()
        mock_repo.select.return_value = [{}, {}]  # Two agent dicts
        mock_repository.return_value = mock_repo
        
        with pytest.raises(ValueError, match="Multiple agents found with name 'Duplicate'"):
            Agent.load('Duplicate')
    
    @patch('percolate.repository')
    def test_load_agent_with_functions(self, mock_repository):
        """Test loading agent with functions"""
        mock_agent_data = {
            'name': 'MyAgent',
            'id': str(uuid.uuid4()),
            'description': "An agent with functions",
            'spec': {
                'type': 'object',
                'properties': {
                    'name': {'type': 'string'}
                },
                'required': ['name']
            },
            'functions': {
                'search': {
                    'description': 'Search for items',
                    'parameters': {'query': {'type': 'string'}}
                }
            },
            'metadata': {}
        }
        
        mock_repo = Mock()
        mock_repo.select.return_value = [mock_agent_data]
        mock_repository.return_value = mock_repo
        
        loaded_model = Agent.load('MyAgent')
        
        assert loaded_model.model_config['functions'] == mock_agent_data['functions']
        assert loaded_model.get_model_namespace() == 'public'  # Default namespace
    
    @patch('percolate.repository')
    def test_load_agent_without_metadata(self, mock_repository):
        """Test loading agent without metadata field"""
        mock_agent_data = {
            'name': 'SimpleAgent',
            'id': str(uuid.uuid4()),
            'description': "A simple agent",
            'spec': {
                'type': 'object',
                'properties': {
                    'value': {'type': 'string'}
                },
                'required': ['value']
            },
            'functions': None
            # No metadata field
        }
        
        mock_repo = Mock()
        mock_repo.select.return_value = [mock_agent_data]
        mock_repository.return_value = mock_repo
        
        loaded_model = Agent.load('SimpleAgent')
        
        # Should still work without metadata
        assert loaded_model.get_model_name() == 'SimpleAgent'
        assert 'agent_id' in loaded_model.model_config
        
        # Create instance
        instance = loaded_model(value="test")
        assert instance.value == "test"
    
    @patch('percolate.repository')
    def test_load_agent_error_handling(self, mock_repository):
        """Test error handling during agent loading"""
        mock_repo = Mock()
        mock_repo.select.side_effect = Exception("Database error")
        mock_repository.return_value = mock_repo
        
        with pytest.raises(Exception, match="Database error"):
            Agent.load('ErrorAgent')
        
        # The error will be logged but we're not testing the logger itself