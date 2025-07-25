"""File upload and resource search tools for MCP"""

from typing import Optional, Dict, Any, List
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository


class FileUploadParams(BaseModel):
    """Parameters for file_upload tool"""
    file_path: str = Field(
        ...,
        description="Local file path to upload"
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
    async def file_upload(params: FileUploadParams) -> Dict[str, Any]:
        """Upload file using admin controller and trigger ingestion"""
        return await repository.upload_file(
            params.file_path,
            params.description,
            params.tags
        )
    
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