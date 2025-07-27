"""Integration test for custom CORS origins configuration"""

import os
import pytest
import requests
from fastapi.testclient import TestClient


def test_default_cors_origins():
    """Test that default CORS origins are applied when no custom origins are set"""
    # Ensure no custom origins are set
    os.environ.pop('P8_CORS_ORIGINS', None)
    
    # Import after environment is cleared to get fresh configuration
    from percolate.api.main import app
    
    client = TestClient(app)
    
    # Test with a default allowed origin
    response = client.options(
        "/",
        headers={
            "Origin": "http://localhost:5008",
            "Access-Control-Request-Method": "GET"
        }
    )
    
    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == "http://localhost:5008"
    assert response.headers.get("access-control-allow-credentials") == "true"


def test_custom_cors_origins_single():
    """Test that custom CORS origins are additive to default origins"""
    # Set custom origin
    os.environ['P8_CORS_ORIGINS'] = "https://custom.example.com"
    
    # Need to reload the module to pick up the new environment variable
    import importlib
    import percolate.utils.env
    import percolate.api.main
    
    importlib.reload(percolate.utils.env)
    importlib.reload(percolate.api.main)
    
    from percolate.api.main import app
    
    client = TestClient(app)
    
    # Test with the custom allowed origin
    response = client.options(
        "/",
        headers={
            "Origin": "https://custom.example.com",
            "Access-Control-Request-Method": "GET"
        }
    )
    
    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == "https://custom.example.com"
    
    # Test that default origins are STILL allowed (additive behavior)
    response = client.options(
        "/",
        headers={
            "Origin": "http://localhost:5008",
            "Access-Control-Request-Method": "GET"
        }
    )
    
    # Should have CORS headers for default origin
    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == "http://localhost:5008"


def test_custom_cors_origins_multiple():
    """Test that custom CORS origins work with multiple comma-separated origins"""
    # Set multiple custom origins
    os.environ['P8_CORS_ORIGINS'] = "https://app1.example.com, https://app2.example.com, https://app3.example.com"
    
    # Reload modules
    import importlib
    import percolate.utils.env
    import percolate.api.main
    
    importlib.reload(percolate.utils.env)
    importlib.reload(percolate.api.main)
    
    from percolate.api.main import app
    
    client = TestClient(app)
    
    # Test each custom origin
    for origin in ["https://app1.example.com", "https://app2.example.com", "https://app3.example.com"]:
        response = client.options(
            "/",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "GET"
            }
        )
        
        assert response.status_code == 200
        assert response.headers.get("access-control-allow-origin") == origin


def test_custom_cors_origins_with_whitespace():
    """Test that custom CORS origins are properly trimmed of whitespace"""
    # Set origins with various whitespace
    os.environ['P8_CORS_ORIGINS'] = "  https://trimmed1.example.com  ,https://trimmed2.example.com,  https://trimmed3.example.com"
    
    # Reload modules
    import importlib
    import percolate.utils.env
    import percolate.api.main
    
    importlib.reload(percolate.utils.env)
    importlib.reload(percolate.api.main)
    
    from percolate.api.main import app
    
    client = TestClient(app)
    
    # Test that trimmed origins work
    for origin in ["https://trimmed1.example.com", "https://trimmed2.example.com", "https://trimmed3.example.com"]:
        response = client.options(
            "/",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "GET"
            }
        )
        
        assert response.status_code == 200
        assert response.headers.get("access-control-allow-origin") == origin


def test_cors_exposed_headers():
    """Test that CORS exposed headers are properly set for TUS uploads"""
    # Clear custom origins
    os.environ.pop('P8_CORS_ORIGINS', None)
    
    # Reload modules
    import importlib
    import percolate.utils.env
    import percolate.api.main
    
    importlib.reload(percolate.utils.env)
    importlib.reload(percolate.api.main)
    
    from percolate.api.main import app
    
    client = TestClient(app)
    
    response = client.options(
        "/",
        headers={
            "Origin": "http://localhost:5008",
            "Access-Control-Request-Method": "GET"
        }
    )
    
    # Check that TUS-related headers are exposed
    exposed_headers = response.headers.get("access-control-expose-headers", "").split(", ")
    assert "Location" in exposed_headers
    assert "Upload-Offset" in exposed_headers
    assert "Upload-Length" in exposed_headers
    assert "Tus-Version" in exposed_headers


def test_production_cors_origin():
    """Test the specific production CORS origin requested"""
    # Set the production origin
    os.environ['P8_CORS_ORIGINS'] = "https://p8.rasmagic.io"
    
    # Reload modules
    import importlib
    import percolate.utils.env
    import percolate.api.main
    
    importlib.reload(percolate.utils.env)
    importlib.reload(percolate.api.main)
    
    from percolate.api.main import app
    
    client = TestClient(app)
    
    # Test the production origin
    response = client.options(
        "/",
        headers={
            "Origin": "https://p8.rasmagic.io",
            "Access-Control-Request-Method": "GET"
        }
    )
    
    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == "https://p8.rasmagic.io"
    
    # Ensure default origins still work
    response = client.options(
        "/",
        headers={
            "Origin": "https://vault.percolationlabs.ai",
            "Access-Control-Request-Method": "GET"
        }
    )
    
    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == "https://vault.percolationlabs.ai"


@pytest.fixture(autouse=True)
def cleanup_env():
    """Cleanup environment variables after each test"""
    yield
    # Clean up
    os.environ.pop('P8_CORS_ORIGINS', None)