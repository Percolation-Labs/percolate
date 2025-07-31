"""Utilities for MCP server implementation.

This module provides common utilities for handling MCP responses,
following the Model Context Protocol (MCP) best practices for
consistent response handling across tools.
"""

from typing import Any, Dict, List, Union, Optional
import logging
from .exceptions import MCPException, ValidationError

logger = logging.getLogger(__name__)


def extract_tool_result(tool_result: Any) -> Any:
    """Extract the actual result from an MCP tool result object.
    
    MCP tool results can be returned in different formats depending on
    the transport and implementation. This function normalizes the extraction
    following MCP best practices:
    
    1. Prioritize structured_content['result'] for JSON-RPC 2.0 compliance
    2. Fall back to data attribute if structured content unavailable
    3. Handle Root() placeholder objects that indicate serialization issues
    4. Provide clear error handling and logging
    
    Args:
        tool_result: The raw result from an MCP tool call
        
    Returns:
        The extracted data in the most usable format
    """
    try:
        # First check structured_content as per MCP JSON-RPC 2.0 standard
        if hasattr(tool_result, 'structured_content') and tool_result.structured_content:
            if isinstance(tool_result.structured_content, dict) and 'result' in tool_result.structured_content:
                logger.debug("Extracted result from structured_content['result']")
                return tool_result.structured_content['result']
            logger.debug("Returning full structured_content")
            return tool_result.structured_content
        
        # Check data attribute, but validate it's not placeholder objects
        if hasattr(tool_result, 'data') and tool_result.data is not None:
            # Detect Root() placeholder objects which indicate serialization issues
            if isinstance(tool_result.data, list) and len(tool_result.data) > 0:
                first_item_type = str(type(tool_result.data[0]))
                if 'Root' in first_item_type:
                    logger.warning(f"Detected Root() placeholder objects in data, checking structured_content")
                    # Try to recover from structured_content
                    if hasattr(tool_result, 'structured_content') and isinstance(tool_result.structured_content, dict):
                        if 'result' in tool_result.structured_content:
                            return tool_result.structured_content['result']
            logger.debug("Returning data attribute")
            return tool_result.data
        
        # Legacy fallback to result attribute
        if hasattr(tool_result, 'result'):
            logger.debug("Using legacy result attribute")
            return tool_result.result
        
        # If none of the expected attributes exist, log warning and return as-is
        logger.warning(f"Tool result has no standard attributes (structured_content, data, result). Type: {type(tool_result)}")
        return tool_result
        
    except Exception as e:
        logger.error(f"Error extracting tool result: {e}", exc_info=True)
        return tool_result


def format_error_response(error: Union[str, Exception, MCPException], code: int = -32603) -> Dict[str, Any]:
    """Format an error response following MCP JSON-RPC 2.0 standards.
    
    Args:
        error: The error message, exception, or MCPException
        code: JSON-RPC error code (default: -32603 for internal error)
        
    Returns:
        Formatted error dictionary
    """
    # If it's an MCPException, use its built-in formatting
    if isinstance(error, MCPException):
        return error.to_error_response()
    
    # Otherwise, use standard formatting
    return {
        "error": {
            "code": code,
            "message": str(error),
            "data": {
                "type": type(error).__name__ if isinstance(error, Exception) else "string"
            }
        }
    }


def validate_tool_params(params: Dict[str, Any], required_fields: List[str]) -> None:
    """Validate that required parameters are present in tool params.
    
    Args:
        params: The parameters dictionary to validate
        required_fields: List of required field names
        
    Raises:
        ValidationError: If required fields are missing
    """
    missing_fields = [field for field in required_fields if field not in params or params[field] is None]
    
    if missing_fields:
        raise ValidationError(
            f"Missing required parameters: {', '.join(missing_fields)}",
            field=missing_fields[0] if len(missing_fields) == 1 else None
        )


def sanitize_response_data(data: Any, max_depth: int = 10) -> Any:
    """Sanitize response data to ensure it's JSON-serializable.
    
    Handles common issues like:
    - Non-serializable objects (converts to string representation)
    - Circular references (via max_depth)
    - None values in lists/dicts
    
    Args:
        data: The data to sanitize
        max_depth: Maximum recursion depth to prevent circular references
        
    Returns:
        Sanitized, JSON-serializable data
    """
    if max_depth <= 0:
        return "<max depth reached>"
    
    if data is None:
        return None
    
    if isinstance(data, (str, int, float, bool)):
        return data
    
    if isinstance(data, dict):
        return {k: sanitize_response_data(v, max_depth - 1) for k, v in data.items()}
    
    if isinstance(data, list):
        return [sanitize_response_data(item, max_depth - 1) for item in data]
    
    # For objects, try to convert to dict or string
    if hasattr(data, '__dict__'):
        try:
            return sanitize_response_data(vars(data), max_depth - 1)
        except:
            pass
    
    # Last resort: string representation
    return str(data)


def try_get_entity_by_type(entity_name: str, model_class: Any, context: Dict[str, Any]) -> Optional[Any]:
    """Try to get an entity by name using a specific model class.
    
    Args:
        entity_name: Name of the entity to retrieve
        model_class: The model class to use for retrieval
        context: User context (user_id, user_groups, role_level)
        
    Returns:
        The entity if found, None otherwise
    """
    import percolate as p8
    
    try:
        repo = p8.repository(
            model_class,
            user_id=context.get("user_id"),
            user_groups=context.get("user_groups", []),
            role_level=context.get("role_level")
        )
        
        # Try get_by_name first if available
        if hasattr(repo, 'get_by_name'):
            try:
                return repo.get_by_name(entity_name, as_model=True)
            except (AttributeError, Exception):
                pass
        
        # Fall back to get_by_id
        if hasattr(repo, 'get_by_id'):
            try:
                return repo.get_by_id(entity_name, as_model=True)
            except (AttributeError, Exception):
                pass
                
        return None
    except Exception:
        return None


def merge_capabilities(base_capabilities: Dict[str, Any], additional: Dict[str, Any]) -> Dict[str, Any]:
    """Merge MCP capability declarations following best practices.
    
    Ensures capability negotiation is handled correctly by merging
    server capabilities while preserving critical settings.
    
    Args:
        base_capabilities: Base capability dictionary
        additional: Additional capabilities to merge
        
    Returns:
        Merged capabilities dictionary
    """
    merged = base_capabilities.copy()
    
    for key, value in additional.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            # Recursively merge nested dictionaries
            merged[key] = merge_capabilities(merged[key], value)
        else:
            merged[key] = value
    
    return merged