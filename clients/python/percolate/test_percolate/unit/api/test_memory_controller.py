"""
Unit tests for UserMemoryController
"""
import pytest
from unittest.mock import patch, MagicMock, AsyncMock
from datetime import datetime, timezone
from uuid import UUID

from percolate.api.controllers.memory import UserMemoryController
from percolate.models.p8.types import UserMemory
from fastapi import HTTPException


class TestUserMemoryController:
    """Test UserMemoryController with mocked dependencies"""
    
    @pytest.fixture
    def controller(self):
        """Create controller instance"""
        return UserMemoryController()
    
    @pytest.fixture
    def mock_repository(self):
        """Mock repository for UserMemory"""
        with patch('percolate.api.controllers.memory.p8.repository') as mock:
            yield mock
    
    @pytest.fixture
    def sample_memory(self):
        """Sample UserMemory instance"""
        return UserMemory(
            id="550e8400-e29b-41d4-a716-446655440000",
            name="amartey_20240101_120000_000",
            userid="amartey@gmail.com",
            content="Test memory content",
            category="user_memory",
            metadata={"test": "data"},
            ordinal=0,
            created_at=datetime.now(timezone.utc),
            updated_at=datetime.now(timezone.utc)
        )
    
    @pytest.mark.asyncio
    async def test_add_memory_success(self, controller, mock_repository, sample_memory):
        """Test successful memory addition"""
        # Setup mock
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        mock_repo_instance.update_records = MagicMock()
        
        # Execute
        with patch('percolate.models.p8.types.UserMemory', return_value=sample_memory):
            result = await controller.add(
                user_id="amartey@gmail.com",
                content="Test memory content",
                metadata={"test": "data"}
            )
        
        # Verify
        assert result == sample_memory
        mock_repository.assert_called_once_with(UserMemory)
        mock_repo_instance.update_records.assert_called_once()
    
    @pytest.mark.asyncio
    async def test_add_memory_with_custom_name(self, controller, mock_repository):
        """Test memory addition with custom name"""
        # Setup mock
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        
        # Execute
        await controller.add(
            user_id="amartey@gmail.com",
            content="Test content",
            name="custom_memory_name",
            category="custom_category"
        )
        
        # Verify repository was called
        mock_repository.assert_called_once_with(UserMemory)
    
    @pytest.mark.asyncio
    async def test_add_memory_failure(self, controller, mock_repository):
        """Test memory addition failure handling"""
        # Setup mock to raise exception
        mock_repository.side_effect = Exception("Database error")
        
        # Execute and verify exception
        with pytest.raises(HTTPException) as exc_info:
            await controller.add(
                user_id="amartey@gmail.com",
                content="Test content"
            )
        
        assert exc_info.value.status_code == 500
        assert "Failed to create memory" in str(exc_info.value.detail)
    
    @pytest.mark.asyncio
    async def test_get_memory_success(self, controller, mock_repository, sample_memory):
        """Test successful memory retrieval"""
        # Setup mock
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        mock_repo_instance.get_entities_by_keys = MagicMock(return_value=[sample_memory])
        
        # Execute
        result = await controller.get(
            user_id="amartey@gmail.com",
            name="amartey_20240101_120000_000"
        )
        
        # Verify
        assert result == sample_memory
        mock_repo_instance.get_entities_by_keys.assert_called_once_with(
            keys=[{"userid": "amartey@gmail.com", "name": "amartey_20240101_120000_000"}],
            as_model=True
        )
    
    @pytest.mark.asyncio
    async def test_get_memory_not_found(self, controller, mock_repository):
        """Test memory retrieval when not found"""
        # Setup mock
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        mock_repo_instance.get_entities_by_keys = MagicMock(return_value=[])
        
        # Execute and verify exception
        with pytest.raises(HTTPException) as exc_info:
            await controller.get(
                user_id="amartey@gmail.com",
                name="non_existent_memory"
            )
        
        assert exc_info.value.status_code == 404
        assert "Memory 'non_existent_memory' not found" in str(exc_info.value.detail)
    
    @pytest.mark.asyncio
    async def test_list_recent_success(self, controller, mock_repository, sample_memory):
        """Test listing recent memories"""
        # Setup mock
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        mock_repo_instance.execute_sql = MagicMock(return_value=[sample_memory])
        
        # Execute
        result = await controller.list_recent(
            user_id="amartey@gmail.com",
            limit=10,
            offset=0
        )
        
        # Verify
        assert result == [sample_memory]
        mock_repo_instance.execute_sql.assert_called_once()
        # Check SQL query contains correct elements
        call_args = mock_repo_instance.execute_sql.call_args
        assert "UserMemory" in call_args[0][0]
        assert "ORDER BY updated_at DESC" in call_args[0][0]
        assert call_args[1]["params"] == ("amartey@gmail.com", 10, 0)
    
    @pytest.mark.asyncio
    async def test_search_memories_with_query(self, controller, mock_repository, sample_memory):
        """Test searching memories with query"""
        # Setup mock
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        mock_repo_instance.search = MagicMock(return_value=[sample_memory])
        
        # Execute
        result = await controller.search(
            user_id="amartey@gmail.com",
            query="test",
            category="user_memory",
            limit=20
        )
        
        # Verify
        assert result == [sample_memory]
        mock_repo_instance.search.assert_called_once_with(
            userid="amartey@gmail.com",
            category="user_memory",
            query="test",
            limit=20,
            as_model=True
        )
    
    @pytest.mark.asyncio
    async def test_search_memories_without_query(self, controller, mock_repository, sample_memory):
        """Test searching memories without query"""
        # Setup mock
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        mock_repo_instance.search = MagicMock(return_value=[sample_memory])
        
        # Execute
        result = await controller.search(
            user_id="amartey@gmail.com",
            limit=50
        )
        
        # Verify
        assert result == [sample_memory]
        mock_repo_instance.search.assert_called_once_with(
            userid="amartey@gmail.com",
            query=None,
            limit=50,
            as_model=True
        )
    
    @pytest.mark.asyncio
    async def test_build_placeholder(self, controller):
        """Test build method returns placeholder"""
        # Execute
        result = await controller.build(user_id="amartey@gmail.com")
        
        # Verify
        assert result["status"] == "not_implemented"
        assert result["user_id"] == "amartey@gmail.com"
        assert "timestamp" in result
    
    @pytest.mark.asyncio
    async def test_delete_memory_success(self, controller, mock_repository, sample_memory):
        """Test successful memory deletion"""
        # Setup mocks
        mock_repo_instance = MagicMock()
        mock_repository.return_value = mock_repo_instance
        mock_repo_instance.delete = MagicMock()
        
        # Mock the get method
        with patch.object(controller, 'get', new_callable=AsyncMock, return_value=sample_memory):
            result = await controller.delete(
                user_id="amartey@gmail.com",
                name="amartey_20240101_120000_000"
            )
        
        # Verify
        assert result is True
        mock_repo_instance.delete.assert_called_once_with(id=sample_memory.id)
    
    @pytest.mark.asyncio
    async def test_delete_memory_not_found(self, controller):
        """Test deletion when memory not found"""
        # Mock the get method to raise 404
        with patch.object(controller, 'get', new_callable=AsyncMock) as mock_get:
            mock_get.side_effect = HTTPException(status_code=404, detail="Not found")
            
            with pytest.raises(HTTPException) as exc_info:
                await controller.delete(
                    user_id="amartey@gmail.com",
                    name="non_existent"
                )
            
            assert exc_info.value.status_code == 404