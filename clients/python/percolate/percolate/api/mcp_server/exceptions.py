"""MCP Server specific exceptions for better error handling."""

from typing import Optional, Any, Dict


class MCPException(Exception):
    """Base exception for all MCP server errors."""
    
    def __init__(self, message: str, code: int = -32603, data: Optional[Dict[str, Any]] = None):
        super().__init__(message)
        self.message = message
        self.code = code
        self.data = data or {}
    
    def to_error_response(self) -> Dict[str, Any]:
        """Convert exception to MCP JSON-RPC error response format."""
        return {
            "error": {
                "code": self.code,
                "message": self.message,
                "data": self.data
            }
        }


class EntityNotFoundError(MCPException):
    """Raised when an entity cannot be found."""
    
    def __init__(self, entity_name: str, entity_type: Optional[str] = None):
        message = f"Entity '{entity_name}' not found"
        if entity_type:
            message += f" (type: {entity_type})"
        super().__init__(message, code=-32001, data={"entity_name": entity_name, "entity_type": entity_type})


class AuthenticationError(MCPException):
    """Raised when authentication fails."""
    
    def __init__(self, message: str = "Authentication failed"):
        super().__init__(message, code=-32002)


class AuthorizationError(MCPException):
    """Raised when user lacks permission for an operation."""
    
    def __init__(self, message: str = "Permission denied"):
        super().__init__(message, code=-32003)


class ValidationError(MCPException):
    """Raised when input validation fails."""
    
    def __init__(self, message: str, field: Optional[str] = None):
        data = {"field": field} if field else {}
        super().__init__(message, code=-32602, data=data)


class RepositoryError(MCPException):
    """Raised when repository operations fail."""
    
    def __init__(self, message: str, operation: Optional[str] = None):
        data = {"operation": operation} if operation else {}
        super().__init__(message, code=-32604, data=data)


class APIError(MCPException):
    """Raised when API calls fail."""
    
    def __init__(self, message: str, status_code: Optional[int] = None, endpoint: Optional[str] = None):
        data = {}
        if status_code:
            data["status_code"] = status_code
        if endpoint:
            data["endpoint"] = endpoint
        super().__init__(message, code=-32605, data=data)


class FunctionExecutionError(MCPException):
    """Raised when function execution fails."""
    
    def __init__(self, function_name: str, message: str):
        super().__init__(
            f"Function '{function_name}' execution failed: {message}",
            code=-32606,
            data={"function_name": function_name}
        )


class FileOperationError(MCPException):
    """Raised when file operations fail."""
    
    def __init__(self, message: str, file_path: Optional[str] = None):
        data = {"file_path": file_path} if file_path else {}
        super().__init__(message, code=-32607, data=data)