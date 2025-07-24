"""Test Agent model creation without mocks"""
import pytest
from percolate.models.p8.types import Agent
from percolate.models.AbstractModel import AbstractModel
from datetime import datetime
import uuid


class TestAgentCreateModel:
    """Test Agent._create_model_from_data functionality without mocks"""
    
    def test_create_model_from_exact_example_data(self):
        """Test creating a model with the exact example data provided"""
        # Exact data from the example (same as what repository returns)
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
        
        # Create the model directly without database/mocks
        loaded_model = Agent._create_model_from_data(agent_data)
        
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
        assert isinstance(instance_with_optionals.target_date, datetime)
    
    def test_create_model_with_functions(self):
        """Test creating model with functions"""
        agent_data = {
            'name': 'MyAgent',
            'id': str(uuid.uuid4()),
            'description': "An agent with functions",
            'spec': {
                'type': 'object',
                'properties': {
                    'name': {'type': 'string'},
                    'value': {'type': 'integer'}
                },
                'required': ['name']
            },
            'functions': {
                'search': {
                    'description': 'Search for items',
                    'parameters': {'query': {'type': 'string'}}
                },
                'calculate': {
                    'description': 'Perform calculations',
                    'parameters': {'x': {'type': 'number'}, 'y': {'type': 'number'}}
                }
            },
            'metadata': {'version': '1.0'}
        }
        
        loaded_model = Agent._create_model_from_data(agent_data)
        
        # Verify model properties
        assert loaded_model.get_model_name() == 'MyAgent'
        assert loaded_model.get_model_namespace() == 'public'  # Default namespace
        assert loaded_model.model_config['functions'] == agent_data['functions']
        assert loaded_model.model_config['version'] == '1.0'
        
        # Create instance
        instance = loaded_model(name="test", value=42)
        assert instance.name == "test"
        assert instance.value == 42
    
    def test_create_model_without_metadata(self):
        """Test creating model without metadata field"""
        agent_data = {
            'name': 'SimpleAgent',
            'id': str(uuid.uuid4()),
            'description': "A simple agent without metadata",
            'spec': {
                'type': 'object',
                'properties': {
                    'value': {'type': 'string', 'description': 'A simple value'}
                },
                'required': ['value']
            },
            'functions': None
            # No metadata field
        }
        
        loaded_model = Agent._create_model_from_data(agent_data)
        
        # Should still work without metadata
        assert loaded_model.get_model_name() == 'SimpleAgent'
        assert 'agent_id' in loaded_model.model_config
        
        # Create instance
        instance = loaded_model(value="test string")
        assert instance.value == "test string"
    
    def test_create_model_with_namespace(self):
        """Test creating model with namespace in name"""
        agent_data = {
            'name': 'custom.namespace.MyModel',
            'id': str(uuid.uuid4()),
            'description': "Model with custom namespace",
            'spec': {
                'type': 'object',
                'properties': {
                    'data': {'type': 'string'}
                },
                'required': ['data']
            },
            'functions': None,
            'metadata': None
        }
        
        loaded_model = Agent._create_model_from_data(agent_data)
        
        assert loaded_model.get_model_name() == 'MyModel'
        assert loaded_model.get_model_namespace() == 'custom.namespace'
        assert loaded_model.get_model_full_name() == 'custom.namespace.MyModel'
    
    def test_create_model_with_complex_types(self):
        """Test creating model with various complex field types"""
        agent_data = {
            'name': 'ComplexTypesAgent',
            'id': str(uuid.uuid4()),
            'description': "Agent demonstrating complex types",
            'spec': {
                'type': 'object',
                'properties': {
                    # Array types
                    'tags': {
                        'type': 'array',
                        'items': {'type': 'string'},
                        'description': 'List of tags'
                    },
                    'scores': {
                        'type': 'array',
                        'items': {'type': 'number'}
                    },
                    # Date types
                    'created_date': {
                        'type': 'string',
                        'format': 'date'
                    },
                    'updated_at': {
                        'type': 'string',
                        'format': 'date-time'
                    },
                    # Constrained types
                    'age': {
                        'type': 'integer',
                        'minimum': 0,
                        'maximum': 150
                    },
                    'username': {
                        'type': 'string',
                        'minLength': 3,
                        'maxLength': 20,
                        'pattern': '^[a-zA-Z0-9_]+$'
                    },
                    # Enum type
                    'status': {
                        'type': 'string',
                        'enum': ['active', 'inactive', 'pending']
                    },
                    # Object type (becomes dict)
                    'metadata': {
                        'type': 'object'
                    }
                },
                'required': ['tags', 'status']
            },
            'functions': None,
            'metadata': {}
        }
        
        loaded_model = Agent._create_model_from_data(agent_data)
        
        # Test instance creation with various types
        from datetime import date
        instance = loaded_model(
            tags=["python", "testing", "model"],
            status="active",
            scores=[95.5, 87.0, 92.3],
            created_date=date.today(),
            updated_at=datetime.now(),
            age=25,
            username="test_user",
            metadata={"key": "value", "nested": {"data": 123}}
        )
        
        # Verify all fields work correctly
        assert len(instance.tags) == 3
        assert instance.status == "active"
        assert len(instance.scores) == 3
        assert isinstance(instance.created_date, date)
        assert isinstance(instance.updated_at, datetime)
        assert instance.age == 25
        assert instance.username == "test_user"
        assert instance.metadata["nested"]["data"] == 123
        
        # Test validation works
        with pytest.raises(ValueError):
            # Invalid enum value
            loaded_model(tags=["test"], status="invalid_status")
    
    def test_model_inherits_abstract_model_interface(self):
        """Test that created models inherit AbstractModel interface"""
        agent_data = {
            'name': 'test.InterfaceTest',
            'id': str(uuid.uuid4()),
            'description': "Test model interface",
            'spec': {
                'type': 'object',
                'properties': {
                    'value': {'type': 'string'}
                },
                'required': ['value']
            },
            'functions': None,
            'metadata': None
        }
        
        loaded_model = Agent._create_model_from_data(agent_data)
        
        # Verify AbstractModel methods are available
        assert hasattr(loaded_model, 'get_model_name')
        assert hasattr(loaded_model, 'get_model_namespace')
        assert hasattr(loaded_model, 'get_model_full_name')
        assert hasattr(loaded_model, 'get_model_table_name')
        assert hasattr(loaded_model, 'get_model_description')
        assert hasattr(loaded_model, 'to_arrow_schema')
        assert hasattr(loaded_model, 'fields_from_json_schema')
        
        # Verify they work correctly
        assert loaded_model.get_model_table_name() == 'test."InterfaceTest"'
        
        # Verify it's a proper AbstractModel
        assert issubclass(loaded_model, AbstractModel)