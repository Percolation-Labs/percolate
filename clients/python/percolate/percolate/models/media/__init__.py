"""Media-related models for Percolate."""

from .audio import (
    AudioFile,
    AudioChunk,
    AudioProcessingStatus,
    AudioUploadResponse,
    AudioPipeline,
    AudioResource,
    ChunkingConfig,
    TranscriptionConfig,
    AudioPipelineConfig,
    register_audio_models
)

from .tus import (
    TusFileUpload,
    TusFileChunk,
    TusUploadStatus,
    TusUploadMetadata,
    TusUploadPatchResponse,
    TusUploadCreationResponse,
    register_tus_models
)

__all__ = [
    # Audio models
    'AudioFile',
    'AudioChunk',
    'AudioProcessingStatus',
    'AudioUploadResponse',
    'AudioPipeline',
    'AudioResource',
    'ChunkingConfig',
    'TranscriptionConfig',
    'AudioPipelineConfig',
    'register_audio_models',
    
    # Tus models
    'TusFileUpload',
    'TusFileChunk',
    'TusUploadStatus',
    'TusUploadMetadata',
    'TusUploadPatchResponse',
    'TusUploadCreationResponse',
    'register_tus_models'
]