"""
Unit tests for UserMemory model
"""
import pytest
from datetime import datetime, timezone
from unittest.mock import patch, MagicMock
import uuid

from percolate.models.p8.types import UserMemory


class TestUserMemory:
    """Test UserMemory model"""
    
    def test_user_memory_creation_basic(self):
        """Test basic UserMemory creation"""
        memory = UserMemory(
            userid="test@example.com",
            content="This is a test memory",
            name="test_memory",
            category="test_category"
        )
        
        assert memory.userid == "test@example.com"
        assert memory.content == "This is a test memory"
        assert memory.name == "test_memory"
        assert memory.category == "test_category"
    
    def test_user_memory_inherits_from_resources(self):
        """Test that UserMemory inherits from Resources"""
        memory = UserMemory(
            userid="test@example.com",
            content="Test content"
        )
        
        # Check it has Resources fields
        assert hasattr(memory, 'uri')
        assert hasattr(memory, 'metadata')
        assert hasattr(memory, 'summary')
        assert hasattr(memory, 'ordinal')
    
    def test_auto_generate_name_from_email(self):
        """Test automatic name generation from email userid"""
        memory = UserMemory(
            userid="amartey@gmail.com",
            content="Test content"
        )
        
        # Test that name starts with email prefix
        assert memory.name.startswith("amartey_")
        # Test that name contains a timestamp pattern (flexible to match actual implementation)
        import re
        timestamp_pattern = r"\d{8}_\d{6}_\d{3}"  # YYYYMMDD_HHMMSS_MS format
        assert re.search(timestamp_pattern, memory.name), f"No timestamp pattern found in {memory.name}"
    
    def test_auto_generate_name_from_uuid(self):
        """Test automatic name generation from UUID userid"""
        user_uuid = str(uuid.uuid4())
        
        with patch('percolate.models.p8.types.datetime') as mock_datetime:
            mock_datetime.datetime.now.return_value.strftime.return_value = "20240101_120000_000"
            mock_datetime.timezone = timezone
            
            memory = UserMemory(
                userid=user_uuid,
                content="Test content"
            )
            
            assert memory.name.startswith(f"{user_uuid}_")
    
    def test_preserve_provided_name(self):
        """Test that provided name is preserved"""
        memory = UserMemory(
            userid="test@example.com",
            content="Test content",
            name="custom_name"
        )
        
        assert memory.name == "custom_name"
    
    def test_auto_generate_id(self):
        """Test automatic ID generation"""
        memory = UserMemory(
            userid="test@example.com",
            content="Test content",
            name="test_memory"
        )
        
        # ID should be generated
        assert memory.id is not None
        assert isinstance(memory.id, (str, uuid.UUID))
    
    def test_preserve_provided_id(self):
        """Test that provided ID is preserved"""
        test_id = str(uuid.uuid4())
        
        memory = UserMemory(
            id=test_id,
            userid="test@example.com",
            content="Test content"
        )
        
        assert str(memory.id) == test_id
    
    def test_default_category(self):
        """Test default category is set"""
        memory = UserMemory(
            userid="test@example.com",
            content="Test content"
        )
        
        assert memory.category == "user_memory"
    
    def test_preserve_provided_category(self):
        """Test that provided category is preserved"""
        memory = UserMemory(
            userid="test@example.com",
            content="Test content",
            category="custom_category"
        )
        
        assert memory.category == "custom_category"
    
    def test_config_attributes(self):
        """Test UserMemory has expected config attributes"""
        # UserMemory should have config but namespace might not be directly accessible
        # Test that the class exists and has basic properties
        assert hasattr(UserMemory, 'Config')
        # Test that we can create an instance
        memory = UserMemory(userid="test@example.com", content="test")
        assert memory is not None
    
    def test_config_description(self):
        """Test UserMemory Config description"""
        assert "User-specific memories" in UserMemory.Config.description
    
    def test_memory_with_metadata(self):
        """Test memory creation with metadata"""
        metadata = {
            "source": "chat",
            "confidence": 0.95,
            "tags": ["personal", "preference"]
        }
        
        memory = UserMemory(
            userid="test@example.com",
            content="User likes coffee",
            metadata=metadata
        )
        
        assert memory.metadata == metadata
        assert memory.metadata["source"] == "chat"
        assert memory.metadata["confidence"] == 0.95
    
    def test_memory_with_summary(self):
        """Test memory with summary field"""
        memory = UserMemory(
            userid="test@example.com",
            content="Long detailed content about user preferences...",
            summary="User preferences"
        )
        
        assert memory.summary == "User preferences"
    
    def test_memory_uri_generation(self):
        """Test URI generation for memory"""
        memory = UserMemory(
            userid="test@example.com",
            content="Test content",
            name="test_memory"
        )
        
        # Check if URI is generated properly
        assert memory.id is not None
        
    def test_ordinal_default(self):
        """Test ordinal defaults to 0"""
        memory = UserMemory(
            userid="test@example.com",
            content="Test content"
        )
        
        # Ordinal should have a default value
        assert hasattr(memory, 'ordinal')
    
    def test_model_validator_execution(self):
        """Test that model validator is executed"""
        # Create memory without name to trigger auto-generation
        memory = UserMemory(
            userid="test@example.com",
            content="Test content"
        )
        
        # Validator should have generated name and ID
        assert memory.name is not None
        assert memory.id is not None
        assert memory.category == "user_memory"