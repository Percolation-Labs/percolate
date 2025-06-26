"""
Test for content upload groupid parameter.
Tests that the upload endpoint properly accepts the groupid parameter.
"""
import pytest
from fastapi import Form


@pytest.mark.slow
def test_upload_endpoint_accepts_groupid_form_parameter():
    """Verify that the upload endpoint signature includes groupid parameter."""
    from percolate.api.routes.admin.router import upload_file
    import inspect
    
    # Get the function signature
    sig = inspect.signature(upload_file)
    
    # Check that groupid parameter exists
    assert 'groupid' in sig.parameters
    
    # Check that it's an optional string Form parameter
    param = sig.parameters['groupid']
    assert param.default.default is None  # Form(None)
    
    # Verify it's a Form parameter
    assert isinstance(param.default, type(Form()))


@pytest.mark.slow
def test_groupid_parameter_is_optional():
    """Verify groupid is optional for backwards compatibility."""
    from percolate.api.routes.admin.router import upload_file
    import inspect
    
    sig = inspect.signature(upload_file)
    param = sig.parameters['groupid']
    
    # Should have a default value (None)
    assert param.default is not inspect.Parameter.empty
    assert param.default.default is None


@pytest.mark.slow
def test_upload_endpoint_structure():
    """Basic test to ensure the upload endpoint exists and has expected structure."""
    from percolate.api.routes.admin import router
    
    # Find the upload route
    upload_route = None
    for route in router.routes:
        if hasattr(route, 'path') and route.path == "/content/upload":
            upload_route = route
            break
    
    assert upload_route is not None, "Upload route not found"
    assert "POST" in route.methods, "Upload route should support POST"