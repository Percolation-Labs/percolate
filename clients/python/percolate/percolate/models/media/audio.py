"""
Models for audio processing in the Percolate framework.
These models represent audio files, chunks, and processing statuses for the audio pipeline.
"""

from pydantic import BaseModel, Field, model_validator
from typing import Optional, List, Dict, Any, Union
from datetime import datetime, timezone
import uuid
from ..AbstractModel import AbstractModel
from percolate.models import DefaultEmbeddingField

class AudioProcessingStatus:
    """Status of an audio file in the processing pipeline"""
    UPLOADING = "uploading"
    UPLOADED = "uploaded"
    PROCESSING = "processing"
    CHUNKING = "chunking"
    TRANSCRIBING = "transcribing"
    COMPLETED = "completed"
    FAILED = "failed"

class AudioFile(AbstractModel):
    """Model representing an uploaded audio file"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    userid: Optional[str | uuid.UUID] = Field(default=None, description="The user id if known")
    project_name: str
    filename: str
    file_size: int
    content_type: str
    duration: Optional[float] = None
    upload_date: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    status: str = AudioProcessingStatus.UPLOADING
    s3_uri: str
    chunks: Optional[List["AudioChunk"]] = None
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)
    
    @model_validator(mode='before')
    @classmethod
    def _v(cls, values):
        """Generate ID if not provided or convert string to UUID"""
        if 'id' not in values or not values['id']:
            values['id'] = uuid.uuid4()
        elif isinstance(values['id'], str):
            # Convert string to UUID if needed
            values['id'] = uuid.UUID(values['id'])
        return values

class AudioChunk(AbstractModel):
    """Model representing a chunk of an audio file for processing"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    audio_file_id: uuid.UUID
    start_time: float
    end_time: float
    duration: float
    s3_uri: str
    transcription: Optional[str] = DefaultEmbeddingField(default='', description='transcribed audio is a resource')
    confidence: Optional[float] = None
    speaker_id: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)
    userid: Optional[str|uuid.UUID] = Field(default=None, description="the audio chunk belongs to a user")
    
    @model_validator(mode='before')
    @classmethod
    def _v(cls, values):
        """Generate ID if not provided or convert string to UUID"""
        if 'id' not in values or not values['id']:
            values['id'] = uuid.uuid4()
        elif isinstance(values['id'], str):
            # Convert string to UUID if needed
            values['id'] = uuid.UUID(values['id'])
            
        # Convert audio_file_id to UUID if it's a string
        if 'audio_file_id' in values and isinstance(values['audio_file_id'], str):
            values['audio_file_id'] = uuid.UUID(values['audio_file_id'])
            
        return values

class AudioUploadResponse(BaseModel):
    """Response model for audio upload endpoint"""
    file_id: uuid.UUID
    filename: str
    status: str
    s3_uri: str

class ChunkingConfig(BaseModel):
    """Configuration for audio chunking"""
    max_chunk_size: float = Field(default=30.0, description="Maximum chunk size in seconds")
    min_chunk_size: float = Field(default=1.0, description="Minimum chunk size in seconds")
    merge_threshold: float = Field(default=0.5, description="Silence threshold for merging in seconds")
    vad_threshold: float = Field(default=0.5, description="Voice activity detection threshold (0.0-1.0)")

class TranscriptionConfig(BaseModel):
    """Configuration for transcription"""
    model: str = Field(default="whisper-1", description="OpenAI Whisper model to use")
    language: Optional[str] = None
    temperature: float = Field(default=0.0, description="Sampling temperature (0.0-1.0)")
    prompt: Optional[str] = None

class AudioPipelineConfig(BaseModel):
    """Configuration for the audio pipeline"""
    chunking: ChunkingConfig = Field(default_factory=ChunkingConfig)
    transcription: TranscriptionConfig = Field(default_factory=TranscriptionConfig)
    retention_period: int = Field(default=90, description="Days to retain audio files in S3")

class AudioPipeline(AbstractModel):
    """Model for tracking audio pipeline execution"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    audio_file_id: str|uuid.UUID
    status: str
    started_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    completed_at: Optional[datetime] = None
    config: Dict[str, Any] = Field(default_factory=dict)
    error_message: Optional[str] = None
    
    @model_validator(mode='before')
    @classmethod
    def _v(cls, values):
        """Generate ID if not provided or convert string to UUID"""
        if 'id' not in values or not values['id']:
            values['id'] = uuid.uuid4()
        elif isinstance(values['id'], str):
            # Convert string to UUID if needed
            values['id'] = uuid.UUID(values['id'])
            
        # Convert audio_file_id to UUID if it's a string
        if 'audio_file_id' in values and isinstance(values['audio_file_id'], str):
            values['audio_file_id'] = uuid.UUID(values['audio_file_id'])
            
        # Set default status if not provided
        if 'status' not in values:
            values['status'] = AudioProcessingStatus.PROCESSING
            
        return values

class AudioResource(AbstractModel):
    """Model for storing audio resources in Percolate"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    uri: str
    name: str
    content_type: str
    content: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    
    @model_validator(mode='before')
    @classmethod
    def _v(cls, values):
        """Generate ID if not provided or convert string to UUID"""
        if 'id' not in values or not values['id']:
            values['id'] = uuid.uuid4()
        elif isinstance(values['id'], str):
            # Convert string to UUID if needed
            values['id'] = uuid.UUID(values['id'])
        return values

def register_audio_models():
    """
    Register all audio models with the Percolate database.
    This function should be called during application startup to ensure 
    all audio-related models are properly registered with the database.
    
    Returns:
        Dict with registration results
    """
    import percolate as p8
    
    models = [
        AudioFile,
        AudioChunk,
        AudioPipeline,
        AudioResource
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

# Reference to support circular references
AudioFile.model_rebuild()