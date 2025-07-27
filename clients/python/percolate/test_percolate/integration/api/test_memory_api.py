"""
Integration tests for UserMemory API endpoints
Requires real database and API server running
"""
import pytest
import requests
import time
from typing import Dict, List
import os

# Get API endpoint from environment
API_ENDPOINT = os.getenv("P8_API_ENDPOINT", "http://localhost:5008")
API_KEY = os.getenv("P8_API_KEY", "postgres")  # Default test bearer token

# Test users
TEST_USERS = ["amartey@gmail.com"]


class TestMemoryAPIIntegration:
    """Integration tests for Memory API endpoints"""
    
    @pytest.fixture
    def headers(self):
        """Get headers with bearer token"""
        return {
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json"
        }
    
    @pytest.fixture
    def base_url(self):
        """Get base URL for memory endpoints"""
        return f"{API_ENDPOINT}/memory"
    
    @pytest.fixture(autouse=True)
    def setup_and_teardown(self, headers, base_url):
        """Clean up test memories before and after tests"""
        # Clean up before test
        self._cleanup_test_memories(headers, base_url)
        
        yield
        
        # Clean up after test
        self._cleanup_test_memories(headers, base_url)
    
    def _cleanup_test_memories(self, headers: Dict, base_url: str):
        """Helper to clean up test memories"""
        try:
            # List all memories
            response = requests.get(
                f"{base_url}/list",
                headers=headers,
                params={"limit": 200}
            )
            
            if response.status_code == 200:
                memories = response.json().get("memories", [])
                
                # Delete test memories (those starting with "test_")
                for memory in memories:
                    if memory["name"].startswith("test_"):
                        requests.delete(
                            f"{base_url}/delete/{memory['name']}",
                            headers=headers
                        )
        except Exception:
            # Ignore cleanup errors
            pass
    
    def test_add_memory_success(self, headers, base_url):
        """Test adding a new memory"""
        # Prepare test data
        test_data = {
            "content": "User prefers dark mode in applications",
            "name": f"test_preference_{int(time.time())}",
            "category": "preferences",
            "metadata": {
                "confidence": 0.9,
                "source": "user_settings"
            }
        }
        
        # Make request
        response = requests.post(
            f"{base_url}/add",
            json=test_data,
            headers=headers
        )
        
        # Verify response
        assert response.status_code == 200
        result = response.json()
        
        assert result["name"] == test_data["name"]
        assert result["content"] == test_data["content"]
        assert result["category"] == test_data["category"]
        assert result["metadata"]["confidence"] == 0.9
        assert result["userid"] is not None
        assert result["id"] is not None
    
    def test_add_memory_auto_name(self, headers, base_url):
        """Test adding memory with auto-generated name"""
        # Prepare test data without name
        test_data = {
            "content": "User is allergic to peanuts",
            "category": "health"
        }
        
        # Make request
        response = requests.post(
            f"{base_url}/add",
            json=test_data,
            headers=headers
        )
        
        # Verify response
        assert response.status_code == 200
        result = response.json()
        
        # Name should be auto-generated
        assert result["name"] is not None
        assert "_" in result["name"]  # Should contain underscore separators
        assert result["content"] == test_data["content"]
    
    def test_get_memory_by_name(self, headers, base_url):
        """Test retrieving a specific memory by name"""
        # First, add a memory
        test_name = f"test_get_{int(time.time())}"
        add_data = {
            "content": "Test memory for retrieval",
            "name": test_name
        }
        
        add_response = requests.post(
            f"{base_url}/add",
            json=add_data,
            headers=headers
        )
        assert add_response.status_code == 200
        
        # Now retrieve it
        get_response = requests.get(
            f"{base_url}/get/{test_name}",
            headers=headers
        )
        
        # Verify response
        assert get_response.status_code == 200
        result = get_response.json()
        
        assert result["name"] == test_name
        assert result["content"] == add_data["content"]
    
    def test_get_memory_not_found(self, headers, base_url):
        """Test retrieving non-existent memory"""
        response = requests.get(
            f"{base_url}/get/non_existent_memory_12345",
            headers=headers
        )
        
        assert response.status_code == 404
        assert "not found" in response.json()["detail"].lower()
    
    def test_list_recent_memories(self, headers, base_url):
        """Test listing recent memories"""
        # Add multiple memories
        memory_names = []
        for i in range(3):
            test_data = {
                "content": f"Test memory {i}",
                "name": f"test_list_{int(time.time())}_{i}"
            }
            
            response = requests.post(
                f"{base_url}/add",
                json=test_data,
                headers=headers
            )
            assert response.status_code == 200
            memory_names.append(test_data["name"])
            
            time.sleep(0.1)  # Small delay to ensure different timestamps
        
        # List memories
        list_response = requests.get(
            f"{base_url}/list",
            headers=headers,
            params={"limit": 10}
        )
        
        # Verify response
        assert list_response.status_code == 200
        result = list_response.json()
        
        assert "memories" in result
        assert "total" in result
        assert result["total"] >= 3
        
        # Check that our test memories are in the list
        listed_names = [m["name"] for m in result["memories"]]
        for name in memory_names:
            assert name in listed_names
    
    def test_list_with_pagination(self, headers, base_url):
        """Test listing memories with pagination"""
        # Add multiple memories
        for i in range(5):
            test_data = {
                "content": f"Pagination test memory {i}",
                "name": f"test_page_{int(time.time())}_{i}"
            }
            
            response = requests.post(
                f"{base_url}/add",
                json=test_data,
                headers=headers
            )
            assert response.status_code == 200
            time.sleep(0.1)
        
        # Get first page
        page1_response = requests.get(
            f"{base_url}/list",
            headers=headers,
            params={"limit": 2, "offset": 0}
        )
        
        assert page1_response.status_code == 200
        page1_result = page1_response.json()
        assert len(page1_result["memories"]) <= 2
        
        # Get second page
        page2_response = requests.get(
            f"{base_url}/list",
            headers=headers,
            params={"limit": 2, "offset": 2}
        )
        
        assert page2_response.status_code == 200
        page2_result = page2_response.json()
        
        # Ensure different memories on different pages
        page1_ids = {m["id"] for m in page1_result["memories"]}
        page2_ids = {m["id"] for m in page2_result["memories"]}
        assert len(page1_ids.intersection(page2_ids)) == 0
    
    def test_search_memories_by_content(self, headers, base_url):
        """Test searching memories by content"""
        # Add memories with specific content
        memories_data = [
            {"content": "User loves Python programming", "name": f"test_search_1_{int(time.time())}"},
            {"content": "User enjoys hiking in mountains", "name": f"test_search_2_{int(time.time())}"},
            {"content": "Python is the preferred language", "name": f"test_search_3_{int(time.time())}"}
        ]
        
        for data in memories_data:
            response = requests.post(f"{base_url}/add", json=data, headers=headers)
            assert response.status_code == 200
        
        # Search for "Python"
        search_response = requests.get(
            f"{base_url}/search",
            headers=headers,
            params={"query": "Python"}
        )
        
        assert search_response.status_code == 200
        result = search_response.json()
        
        # Should find at least 2 memories with "Python"
        assert result["total"] >= 2
        
        # Verify search results contain query term
        for memory in result["memories"]:
            assert "python" in memory["content"].lower()
    
    def test_search_memories_by_category(self, headers, base_url):
        """Test searching memories by category"""
        # Add memories with different categories
        categories_data = [
            {"content": "Likes spicy food", "category": "food_preferences", "name": f"test_cat_1_{int(time.time())}"},
            {"content": "Allergic to shellfish", "category": "health", "name": f"test_cat_2_{int(time.time())}"},
            {"content": "Prefers Italian cuisine", "category": "food_preferences", "name": f"test_cat_3_{int(time.time())}"}
        ]
        
        for data in categories_data:
            response = requests.post(f"{base_url}/add", json=data, headers=headers)
            assert response.status_code == 200
        
        # Search by category
        search_response = requests.get(
            f"{base_url}/search",
            headers=headers,
            params={"category": "food_preferences"}
        )
        
        assert search_response.status_code == 200
        result = search_response.json()
        
        # Should find exactly 2 food_preferences memories
        food_memories = [m for m in result["memories"] if m["category"] == "food_preferences"]
        assert len(food_memories) >= 2
    
    def test_delete_memory(self, headers, base_url):
        """Test deleting a memory"""
        # First, add a memory
        test_name = f"test_delete_{int(time.time())}"
        add_data = {
            "content": "Memory to be deleted",
            "name": test_name
        }
        
        add_response = requests.post(
            f"{base_url}/add",
            json=add_data,
            headers=headers
        )
        assert add_response.status_code == 200
        
        # Delete the memory
        delete_response = requests.delete(
            f"{base_url}/delete/{test_name}",
            headers=headers
        )
        
        assert delete_response.status_code == 200
        assert delete_response.json()["success"] is True
        
        # Verify it's deleted
        get_response = requests.get(
            f"{base_url}/get/{test_name}",
            headers=headers
        )
        assert get_response.status_code == 404
    
    def test_build_endpoint(self, headers, base_url):
        """Test build endpoint (placeholder)"""
        response = requests.post(
            f"{base_url}/build",
            headers=headers
        )
        
        assert response.status_code == 200
        result = response.json()
        
        assert result["status"] == "not_implemented"
        assert "user_id" in result
        assert "timestamp" in result
    
    def test_unauthorized_access(self, base_url):
        """Test accessing API without authentication"""
        # Try to add memory without auth header
        response = requests.post(
            f"{base_url}/add",
            json={"content": "Test content"}
        )
        
        assert response.status_code == 401
    
    def test_invalid_bearer_token(self, base_url):
        """Test accessing API with invalid token"""
        headers = {
            "Authorization": "Bearer invalid_token_12345",
            "Content-Type": "application/json"
        }
        
        response = requests.post(
            f"{base_url}/add",
            json={"content": "Test content"},
            headers=headers
        )
        
        assert response.status_code == 401