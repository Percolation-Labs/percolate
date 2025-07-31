"""File upload and resource search tools for MCP"""

from typing import Optional, Dict, Any, List
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository
from ..utils import format_error_response, validate_tool_params


class FileUploadParams(BaseModel):
    """Parameters for file_upload tool"""
    file_content: Optional[str] = Field(
        None,
        description="File content to upload (for MCP clients that can't access local files)"
    )
    file_path: Optional[str] = Field(
        None,
        description="Local file path to upload (for direct file system access)"
    )
    filename: Optional[str] = Field(
        None,
        description="Filename for the upload (required when using file_content)"
    )
    namespace: Optional[str] = Field(
        None,
        description="Namespace to upload to (defaults to P8_DEFAULT_NAMESPACE)"
    )
    entity_name: Optional[str] = Field(
        None,
        description="Entity to associate with (defaults to P8_DEFAULT_ENTITY)"
    )
    task_id: Optional[str] = Field(
        None,
        description="Optional task ID for tracking"
    )
    description: Optional[str] = Field(
        None,
        description="Optional description for the uploaded file"
    )
    tags: Optional[List[str]] = Field(
        None,
        description="Optional tags to associate with the file"
    )


class ResourceSearchParams(BaseModel):
    """Parameters for resource_search tool"""
    query: str = Field(
        ...,
        description="Search query to find matching resources"
    )
    resource_type: Optional[str] = Field(
        None,
        description="Optional resource type filter (e.g., 'document', 'image', 'data')"
    )
    limit: int = Field(
        10,
        description="Maximum number of results to return",
        ge=1,
        le=100
    )


def create_file_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create file and resource related MCP tools"""
    
    @mcp.tool(
        name="file_upload",
        description="Upload a file to Percolate for ingestion and embedding",
        annotations={
            "hint": {"readOnlyHint": False, "idempotentHint": False},
            "tags": ["file", "upload", "ingest", "resource"]
        }
    )
    async def file_upload(params: FileUploadParams) -> str:
        """Upload file using admin controller and trigger ingestion"""
        # Get default configuration
        from ..config import get_mcp_settings
        settings = get_mcp_settings()
        
        # Use defaults if not provided
        namespace = params.namespace or settings.default_namespace
        entity_name = params.entity_name or settings.default_entity
        
        # Support both file_content and file_path
        if params.file_content and params.filename:
            # Upload from content (MCP client mode)
            result = await repository.upload_file_content(
                file_content=params.file_content,
                filename=params.filename,
                namespace=namespace,
                entity_name=entity_name,
                task_id=params.task_id,
                description=params.description,
                tags=params.tags
            )
        elif params.file_path:
            # Upload from path (direct file access mode)
            result = await repository.upload_file(
                file_path=params.file_path,
                namespace=namespace,
                entity_name=entity_name,
                task_id=params.task_id,
                description=params.description,
                tags=params.tags
            )
        else:
            result = format_error_response("Either file_content with filename or file_path must be provided", code=-32602)
        
        # Format result as text for MCP
        if result.get("success"):
            return f"""✅ File Upload Successful

**File**: {result.get('file_name', 'Unknown')}
**Size**: {result.get('file_size', 0):,} bytes
**Namespace**: {namespace}
**Entity**: {entity_name}
**Resource ID**: {result.get('resource_id', result.get('key', 'N/A'))}
**S3 Location**: {result.get('s3_url', result.get('key', 'N/A'))}

{result.get('message', 'File uploaded successfully. Background processing will index content.')}"""
        else:
            return f"""❌ File Upload Failed

**Error**: {result.get('error', 'Unknown error')}
**File**: {result.get('filename', result.get('file_path', 'Unknown'))}

Please check your file and try again."""
    
    @mcp.tool(
        name="resource_search",
        description="Search for resources in Percolate using the Resource model",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": True},
            "tags": ["resource", "search", "file", "document"]
        }
    )
    async def resource_search(params: ResourceSearchParams) -> List[Dict[str, Any]]:
        """Search resources and return raw results"""
        return await repository.search_resources(
            params.query,
            params.resource_type,
            params.limit
        )