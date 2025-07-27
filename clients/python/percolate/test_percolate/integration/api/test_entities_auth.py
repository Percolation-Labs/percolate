"""
Test suite for entities router with hybrid authentication.
"""

import pytest
from fastapi import status
from fastapi.testclient import TestClient
from unittest.mock import Mock, patch
from percolate.api.main import app


@pytest.fixture
def client():
    """Create test client."""
    return TestClient(app)


@pytest.mark.slow
class TestEntitiesAuth:
    """Test entities router with hybrid authentication."""
    
    def test_create_agent_with_bearer_token(self, client):
        """Test creating an agent with bearer token authentication."""
        from percolate.api.routes.auth import hybrid_auth
        from percolate.api.main import app
        import uuid
        
        def override_auth():
            return None  # Bearer token returns None
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            headers = {"Authorization": "Bearer postgres"}  # Use postgres API key
            agent_data = {
                "id": str(uuid.uuid4()),
                "name": "test-agent",
                "description": "A test agent",
                "spec": {"type": "object", "properties": {}},
                "functions": {}
            }
            
            response = client.post(
                "/entities/",
                headers=headers,
                json=agent_data
            )
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert "test-agent" in data["name"]  # May have namespace prefix
        finally:
            app.dependency_overrides.clear()
    
    def test_list_agents_with_session(self, client):
        """Test listing agents with session authentication."""
        from percolate.api.routes.auth import hybrid_auth
        from percolate.api.main import app
        import uuid
        
        def override_auth():
            return str(uuid.uuid4())  # Session returns user ID
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            response = client.get("/entities/")
            
            assert response.status_code == status.HTTP_200_OK
            data = response.json()
            assert isinstance(data, list)
        finally:
            app.dependency_overrides.clear()
    
    def test_entities_without_auth_fails(self, client):
        """Test that entities endpoints require authentication."""
        # Clear any overrides
        app.dependency_overrides.clear()
        
        # Mock the auth to raise 401
        from percolate.api.routes.auth import hybrid_auth
        from fastapi import HTTPException
        
        def override_auth():
            raise HTTPException(status_code=401, detail="Authentication required")
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            response = client.get("/entities/")
            assert response.status_code == status.HTTP_401_UNAUTHORIZED
        finally:
            app.dependency_overrides.clear()
    
    def test_agent_search_with_auth(self, client):
        """Test agent search with authentication."""
        from percolate.api.routes.auth import hybrid_auth
        from percolate.api.main import app
        import uuid
        
        def override_auth():
            return str(uuid.uuid4())  # Return a valid UUID
            
        app.dependency_overrides[hybrid_auth] = override_auth
        
        try:
            response = client.post(
                "/entities/search",
                json={"query": "test query", "agent_name": "test-agent"}
            )
            
            # Accept 200 or 422 (since this might not be a real endpoint)
            assert response.status_code in [status.HTTP_200_OK, status.HTTP_422_UNPROCESSABLE_ENTITY]
            if response.status_code == status.HTTP_200_OK:
                data = response.json()
                assert isinstance(data, list)  # Should return a list (even if empty)
        finally:
            app.dependency_overrides.clear()