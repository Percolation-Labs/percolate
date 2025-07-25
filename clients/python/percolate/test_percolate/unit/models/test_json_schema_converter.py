import pytest
from pydantic import BaseModel, Field, create_model
from percolate.models.AbstractModel import AbstractModel
from percolate.utils.types.pydantic import JsonSchemaConverter
from datetime import date, datetime
from typing import List, Optional


class TestJsonSchemaConverter:
    """Test JSON Schema to Pydantic field conversion"""
    
    def test_basic_types(self):
        """Test conversion of basic JSON Schema types"""
        json_schema = {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "User's name"},
                "age": {"type": "integer", "description": "User's age"},
                "height": {"type": "number", "description": "Height in meters"},
                "is_active": {"type": "boolean", "description": "Active status"}
            },
            "required": ["name", "age"]
        }
        
        fields = JsonSchemaConverter.fields_from_json_schema(json_schema)
        
        # Check field types
        assert fields["name"][0] == str
        assert fields["age"][0] == int
        assert fields["height"][0] == Optional[float]  # Not required
        assert fields["is_active"][0] == Optional[bool]  # Not required
        
        # Check descriptions
        assert fields["name"][1].description == "User's name"
        assert fields["age"][1].description == "User's age"
        
        # Test model creation
        TestModel = create_model("TestModel", **fields)
        instance = TestModel(name="John", age=30)
        assert instance.name == "John"
        assert instance.age == 30
    
    def test_array_types(self):
        """Test conversion of array types"""
        json_schema = {
            "type": "object",
            "properties": {
                "tags": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "List of tags"
                },
                "scores": {
                    "type": "array",
                    "items": {"type": "number"}
                }
            }
        }
        
        fields = JsonSchemaConverter.fields_from_json_schema(json_schema)
        
        assert fields["tags"][0] == Optional[List[str]]
        assert fields["scores"][0] == Optional[List[float]]
    
    def test_date_formats(self):
        """Test conversion of date/datetime formats"""
        json_schema = {
            "type": "object",
            "properties": {
                "birth_date": {
                    "type": "string",
                    "format": "date"
                },
                "created_at": {
                    "type": "string",
                    "format": "date-time"
                }
            }
        }
        
        fields = JsonSchemaConverter.fields_from_json_schema(json_schema)
        
        assert fields["birth_date"][0] == Optional[date]
        assert fields["created_at"][0] == Optional[datetime]
    
    def test_constraints(self):
        """Test field constraints from JSON Schema"""
        json_schema = {
            "type": "object",
            "properties": {
                "username": {
                    "type": "string",
                    "minLength": 3,
                    "maxLength": 20,
                    "pattern": "^[a-zA-Z0-9_]+$"
                },
                "age": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 150
                }
            }
        }
        
        fields = JsonSchemaConverter.fields_from_json_schema(json_schema)
        
        # Check constraints - in Pydantic v2, constraints are stored in metadata
        username_field = fields["username"][1]
        # Extract constraint values from metadata
        username_metadata = username_field.metadata if hasattr(username_field, 'metadata') else []
        min_len = next((m.min_length for m in username_metadata if hasattr(m, 'min_length')), None)
        max_len = next((m.max_length for m in username_metadata if hasattr(m, 'max_length')), None)
        pattern = next((m.pattern for m in username_metadata if hasattr(m, 'pattern')), None)
        
        assert min_len == 3
        assert max_len == 20
        assert pattern == "^[a-zA-Z0-9_]+$"
        
        age_field = fields["age"][1]
        # For numeric constraints
        age_metadata = age_field.metadata if hasattr(age_field, 'metadata') else []
        ge_val = next((m.ge for m in age_metadata if hasattr(m, 'ge')), None)
        le_val = next((m.le for m in age_metadata if hasattr(m, 'le')), None)
        
        assert ge_val == 0
        assert le_val == 150
    
    def test_enum_types(self):
        """Test enum conversion"""
        json_schema = {
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "enum": ["active", "inactive", "pending"]
                }
            }
        }
        
        fields = JsonSchemaConverter.fields_from_json_schema(json_schema)
        
        # Create model and test enum values
        TestModel = create_model("TestModel", **fields)
        instance = TestModel(status="active")
        assert instance.status == "active"
        
        # Should raise error for invalid enum value
        with pytest.raises(ValueError):
            TestModel(status="invalid")
    
    def test_defaults(self):
        """Test default values"""
        json_schema = {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "default": "Anonymous"
                },
                "count": {
                    "type": "integer",
                    "default": 0
                }
            }
        }
        
        fields = JsonSchemaConverter.fields_from_json_schema(json_schema)
        
        TestModel = create_model("TestModel", **fields)
        instance = TestModel()
        assert instance.name == "Anonymous"
        assert instance.count == 0
    
    def test_abstract_model_integration(self):
        """Test integration with AbstractModel.fields_from_json_schema"""
        json_schema = {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "value": {"type": "number"}
            },
            "required": ["id"]
        }
        
        fields = AbstractModel.fields_from_json_schema(json_schema)
        
        # Create a model using AbstractModel.create_model
        DynamicModel = AbstractModel.create_model(
            "DynamicModel",
            fields=fields
        )
        
        instance = DynamicModel(id="test123", value=42.5)
        assert instance.id == "test123"
        assert instance.value == 42.5
        
        # Test that it inherits AbstractModel methods
        assert hasattr(DynamicModel, 'get_model_name')
        assert DynamicModel.get_model_name() == "DynamicModel"
    
    def test_backward_compatibility(self):
        """Test backward compatibility with simplified format"""
        # Old format
        simple_schema = {
            "name": {
                "type": "str",
                "description": "Name field"
            },
            "count": {
                "type": "int",
                "default": 0
            }
        }
        
        fields = JsonSchemaConverter.fields_from_json_schema(simple_schema)
        
        assert fields["name"][0] == str
        assert fields["count"][0] == int
        assert fields["count"][1].default == 0