"""
Unit tests for p8.tool decorator
"""
import pytest
import percolate as p8


def test_tool_decorator():
    """Test that p8.tool decorator adds correct attributes"""
    
    # Test with default access level (100)
    @p8.tool()
    def public_function():
        return "public"
    
    assert hasattr(public_function, '_p8_access_required')
    assert hasattr(public_function, '_p8_is_tool')
    assert public_function._p8_access_required == 100
    assert public_function._p8_is_tool is True
    
    # Test with custom access level
    @p8.tool(access_required=10)
    def partner_function():
        return "partner"
    
    assert partner_function._p8_access_required == 10
    assert partner_function._p8_is_tool is True
    
    # Test with admin access level
    @p8.tool(access_required=1)
    def admin_function():
        return "admin"
    
    assert admin_function._p8_access_required == 1
    assert admin_function._p8_is_tool is True
    
    # Test that functions still work normally
    assert public_function() == "public"
    assert partner_function() == "partner"
    assert admin_function() == "admin"


def test_tool_decorator_with_args():
    """Test that p8.tool decorator preserves function signatures"""
    
    @p8.tool(access_required=50)
    def function_with_args(x: int, y: str = "default") -> str:
        """Test function with arguments"""
        return f"{x}-{y}"
    
    # Check attributes
    assert function_with_args._p8_access_required == 50
    assert function_with_args._p8_is_tool is True
    
    # Check function still works
    assert function_with_args(42) == "42-default"
    assert function_with_args(42, "custom") == "42-custom"
    
    # Check docstring is preserved
    assert function_with_args.__doc__ == "Test function with arguments"