"""
Models for Tus protocol file uploads in the Percolate framework.
These models represent file uploads, chunks, and processing statuses for the Tus protocol.
"""

from pydantic import BaseModel, Field, model_validator
from typing import Optional, List, Dict, Any, Union
from datetime import datetime, timezone
import uuid
import logging
from enum import Enum
from ..AbstractModel import AbstractModel
from percolate.models import DefaultEmbeddingField

# We'll use string literals instead of enum for compatibility
class TusUploadStatus:
    """Status of a Tus file upload in the processing pipeline"""
    INITIATED = "initiated"       # Upload initiated but no chunks uploaded yet
    IN_PROGRESS = "in_progress"   # Upload has chunks but is not complete
    COMPLETED = "completed"       # Upload is completed successfully
    PROCESSING = "processing"     # File is being processed post-upload
    FAILED = "failed"             # Upload failed
    EXPIRED = "expired"           # Upload expired (not completed within TTL)

class TusFileUpload(AbstractModel):
    """Model representing a Tus protocol file upload"""
    model_config = {'namespace': 'public'}
    
    id: Union[str, uuid.UUID] = Field(default_factory=uuid.uuid4, description="Unique ID for the file upload")
    userid: Optional[Union[str, uuid.UUID]] = Field(default=None, description="The user id if known")
    filename: str = Field(description="Original filename provided by client")
    content_type: Optional[str] = Field(default=None, description="MIME type of the file")
    total_size: int = Field(description="Total size of the file in bytes")
    uploaded_size: int = Field(default=0, description="Total bytes received so far")
    status: str = Field(default=TusUploadStatus.INITIATED)
    upload_uri: str = Field(description="URI for the upload location")
    s3_uri: Optional[str] = Field(default=None, description="S3 URI where the finalized file is stored")
    s3_bucket: Optional[str] = Field(default=None, description="S3 bucket where the file is stored")
    s3_key: Optional[str] = Field(default=None, description="S3 key (path) where the file is stored")
    upload_metadata: Optional[Dict[str, Any]] = Field(default_factory=dict, description="Metadata sent with the upload")
    project_name: Optional[str] = Field(default=None, description="Project this upload belongs to")
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    expires_at: Optional[datetime] = Field(default=None, description="When this upload expires")
    tags: List[str] = Field(default_factory=list, description="Up to three tags for categorizing the file")
    resource_id: Optional[Union[str, uuid.UUID]] = Field(default=None, description="Reference to a resource ID for this file")
    
    @model_validator(mode='before')
    @classmethod
    def _validate_id(cls, values):
        """Generate ID if not provided or ensure it's a proper UUID or string"""
        if 'id' not in values or not values['id']:
            values['id'] = str(uuid.uuid4())
        elif isinstance(values['id'], str) and not values['id'].startswith('{') and not values['id'].startswith('urn:'):
            try:
                # Only convert to UUID if it's a valid UUID string but not already formatted
                uuid_obj = uuid.UUID(values['id'])
                values['id'] = str(uuid_obj)
            except ValueError:
                # Keep as string if it's not a valid UUID
                pass
            
        if values.get('userid'):
            if isinstance(values['userid'], str) and not values['userid'].startswith('{') and not values['userid'].startswith('urn:'):
                try:
                    uuid_obj = uuid.UUID(values['userid'])
                    values['userid'] = str(uuid_obj)
                except ValueError:
                    pass
            
        if values.get('resource_id'):
            if isinstance(values['resource_id'], str) and not values['resource_id'].startswith('{') and not values['resource_id'].startswith('urn:'):
                try:
                    uuid_obj = uuid.UUID(values['resource_id'])
                    values['resource_id'] = str(uuid_obj)
                except ValueError:
                    pass
            
        # Limit to max 3 tags
        if 'tags' in values and values['tags']:
            if isinstance(values['tags'], list) and len(values['tags']) > 3:
                values['tags'] = values['tags'][:3]
                
        return values
        
    @property
    def has_tags(self) -> bool:
        """Check if upload has tags"""
        return bool(self.tags and len(self.tags) > 0)
        
    @property
    def has_resource(self) -> bool:
        """Check if upload has a resource reference"""
        return self.resource_id is not None

class TusFileChunk(AbstractModel):
    """Model representing a chunk of a Tus file upload"""
    model_config = {'namespace': 'public'}
    
    id: Union[str, uuid.UUID] = Field(default_factory=uuid.uuid4, description="Unique ID for the chunk")
    upload_id: Union[str, uuid.UUID] = Field(description="The parent upload ID")
    chunk_size: int = Field(description="Size of this chunk in bytes")
    chunk_offset: int = Field(description="Offset in the file where this chunk begins")  # Changed from 'offset' to avoid reserved keyword
    storage_path: str = Field(description="Path where chunk is stored")
    s3_uri: Optional[str] = Field(default=None, description="S3 URI if chunk is stored in S3")
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    
    @model_validator(mode='before')
    @classmethod
    def _validate_id(cls, values):
        """Generate ID if not provided or ensure it's a proper UUID or string"""
        if 'id' not in values or not values['id']:
            values['id'] = str(uuid.uuid4())
        elif isinstance(values['id'], str) and not values['id'].startswith('{') and not values['id'].startswith('urn:'):
            try:
                # Only convert to UUID if it's a valid UUID string but not already formatted
                uuid_obj = uuid.UUID(values['id'])
                values['id'] = str(uuid_obj)
            except ValueError:
                # Keep as string if it's not a valid UUID
                pass
            
        if values.get('upload_id'):
            if isinstance(values['upload_id'], str) and not values['upload_id'].startswith('{') and not values['upload_id'].startswith('urn:'):
                try:
                    uuid_obj = uuid.UUID(values['upload_id'])
                    values['upload_id'] = str(uuid_obj)
                except ValueError:
                    pass
            
        return values

class TusUploadMetadata(BaseModel):
    """Response model for upload metadata"""
    id: Union[str, uuid.UUID]
    filename: str
    content_type: Optional[str] = None
    total_size: int
    uploaded_size: int
    status: str
    created_at: datetime
    updated_at: datetime
    expires_at: Optional[datetime] = None
    upload_metadata: Dict[str, Any] = Field(default_factory=dict)
    tags: List[str] = Field(default_factory=list)
    resource_id: Optional[Union[str, uuid.UUID]] = None
    has_resource: bool = False
    s3_uri: Optional[str] = None
    s3_bucket: Optional[str] = None
    s3_key: Optional[str] = None

class TusUploadPatchResponse(BaseModel):
    """Response model for PATCH requests"""
    offset: int
    upload_id: Union[str, uuid.UUID]
    expires_at: Optional[datetime] = None

class TusUploadCreationResponse(BaseModel):
    """Response model for POST requests to create a new upload"""
    upload_id: Union[str, uuid.UUID]
    location: str
    expires_at: Optional[datetime] = None


class UserUploadSearchRequest(BaseModel):
    """Request model for searching user uploads"""
    query_text: Optional[str] = Field(None, description="Semantic search query")
    tags: Optional[List[str]] = Field(None, description="Filter by tags")
    limit: int = Field(default=20, gt=0, le=100, description="Maximum results to return")


class UserUploadSearchResult(BaseModel):
    """Response model for user upload search results"""
    upload_id: str
    filename: str
    content_type: Optional[str]
    total_size: int
    uploaded_size: int
    status: str
    created_at: datetime
    updated_at: datetime
    s3_uri: Optional[str]
    tags: Optional[List[str]]
    resource_id: Optional[str]
    # Resource-related fields when available
    resource_uri: Optional[str]
    resource_name: Optional[str]
    chunk_count: Optional[int]
    resource_size: Optional[int]
    indexed_at: Optional[datetime]
    semantic_score: Optional[float]

def register_tus_models():
    """
    Register all Tus file upload models with the Percolate database.
    This function should be called during application startup to ensure 
    all Tus-related models are properly registered with the database.
    
    Returns:
        Dict with registration results
    """
    import percolate as p8
    
    models = [
        TusFileUpload,
        TusFileChunk
    ]
    
    results = {}
    
    for model in models:
        model_name = model.__name__
        try:
            # Register the model with Percolate
            p8.repository(model).register()
            results[model_name] = "Registered successfully"
        except Exception as e:
            results[model_name] = f"Failed: {str(e)}"
    
    return results

# Initialize models to support circular references
TusFileUpload.model_rebuild()
TusFileChunk.model_rebuild()