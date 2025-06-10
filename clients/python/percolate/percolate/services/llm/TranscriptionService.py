"""
Transcription service abstraction for Percolate.
Provides transcription capabilities for audio and video files using OpenAI Whisper API.
Supports both official OpenAI client and raw requests (for servers without openai dependency).
"""

import os
import tempfile
from typing import Optional, Tuple
from pathlib import Path
from percolate.utils import logger
import requests
import urllib3

# Try to use the official OpenAI client if available
try:
    from openai import OpenAI
    OPENAI_CLIENT_AVAILABLE = True
except ImportError:
    OPENAI_CLIENT_AVAILABLE = False
    logger.info("OpenAI client library not available, falling back to requests")

# SSL/TLS configuration for requests fallback
try:
    # Disable SSL warnings for urllib3 < 2.0 if needed
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
except:
    pass


class TranscriptionService:
    """
    Service for transcribing audio and video files using OpenAI Whisper API.
    """
    
    def __init__(self, api_key: Optional[str] = None, prefer_requests: bool = False):
        """
        Initialize the transcription service.
        
        Args:
            api_key: OpenAI API key. If not provided, will try to get from environment.
            prefer_requests: If True, use requests instead of OpenAI client even if available.
        """
        self.api_key = api_key or self._get_openai_key()
        self.base_url = "https://api.openai.com/v1/audio/transcriptions"
        self.use_client = False
        self.client = None
        
        # Check environment variable for global preference
        env_prefer_requests = os.environ.get('P8_TRANSCRIPTION_USE_REQUESTS', 'false').lower() == 'true'
        prefer_requests = prefer_requests or env_prefer_requests
        
        # Decide which method to use
        if OPENAI_CLIENT_AVAILABLE and not prefer_requests and self.api_key:
            try:
                self.client = OpenAI(
                    api_key=self.api_key,
                    timeout=120.0,
                    max_retries=3
                )
                self.use_client = True
                logger.info("Using OpenAI client library for transcription")
            except Exception as e:
                logger.warning(f"Failed to initialize OpenAI client: {e}, falling back to requests")
        
        if not self.use_client:
            logger.info("Using requests library for transcription with SSL fixes")
        
    def _get_openai_key(self) -> Optional[str]:
        """Get OpenAI API key from environment or service."""
        # Try environment variable first
        api_key = os.environ.get("OPENAI_API_KEY")
        if api_key:
            return api_key
            
        # Try the existing service method
        try:
            from percolate.services.llm.LanguageModel import try_get_open_ai_key
            return try_get_open_ai_key()
        except ImportError:
            logger.warning("Could not import OpenAI key function")
            return None
    
    def is_available(self) -> bool:
        """Check if transcription service is available."""
        return self.api_key is not None
    
    def transcribe_file(self, file_path: str) -> Tuple[str, float]:
        """
        Transcribe an audio or video file.
        
        Args:
            file_path: Path to the audio/video file
            
        Returns:
            Tuple of (transcription_text, confidence_score)
            
        Raises:
            ValueError: If service is not available
            Exception: If transcription fails
        """
        if not self.is_available():
            raise ValueError("OpenAI API key not available for transcription")
        
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"Audio file not found: {file_path}")
        
        # Check file size (OpenAI has a 25MB limit)
        file_size = os.path.getsize(file_path)
        if file_size > 25 * 1024 * 1024:  # 25MB
            raise ValueError(f"File too large for transcription: {file_size / (1024*1024):.1f}MB (max 25MB)")
        
        logger.info(f"Transcribing file: {file_path} ({file_size / (1024*1024):.1f}MB)")
        
        if self.use_client:
            return self._transcribe_with_client(file_path)
        else:
            return self._transcribe_with_requests(file_path)
    
    def _transcribe_with_client(self, file_path: str) -> Tuple[str, float]:
        """Transcribe using the official OpenAI client."""
        try:
            # Verify the file format before sending to OpenAI
            file_ext = os.path.splitext(file_path)[1].lower()
            
            # Log file details
            file_size_mb = os.path.getsize(file_path) / (1024*1024)
            logger.info(f"Preparing to transcribe: {file_path} ({file_size_mb:.2f}MB, format: {file_ext})")
            
            # Special handling for WAV files to ensure they're properly formatted
            if file_ext == '.wav':
                # Try to validate the WAV file
                try:
                    import wave
                    with wave.open(file_path, 'rb') as wav_file:
                        # Extract basic info
                        channels, sample_width, frame_rate, n_frames, comp_type, comp_name = wav_file.getparams()
                        logger.info(f"WAV file info: channels={channels}, rate={frame_rate}, frames={n_frames}")
                except Exception as wav_error:
                    logger.warning(f"WAV file validation failed: {str(wav_error)}. File may be corrupted or in non-standard format.")
            
            # Proceed with transcription
            with open(file_path, "rb") as audio_file:
                transcript = self.client.audio.transcriptions.create(
                    model="whisper-1",
                    file=audio_file,
                    response_format="text"
                )
                
            transcription = transcript.strip() if isinstance(transcript, str) else str(transcript).strip()
            confidence = 0.9  # OpenAI doesn't provide confidence scores
            logger.info(f"Transcription successful: {len(transcription)} characters")
            return transcription, confidence
            
        except Exception as e:
            error_msg = f"Transcription failed: {str(e)}"
            logger.error(error_msg)
            raise Exception(error_msg)
    
    def _transcribe_with_requests(self, file_path: str) -> Tuple[str, float]:
        """Transcribe using requests library with SSL fixes."""
        try:
            # Prepare the request with SSL fixes
            headers = {"Authorization": f"Bearer {self.api_key}"}
            
            # Create a session with SSL configuration
            session = requests.Session()
            
            # SSL/TLS configuration to fix the EOF protocol violation
            session.verify = True  # Keep SSL verification enabled
            
            # Configure SSL adapter with specific settings
            from requests.adapters import HTTPAdapter
            from urllib3.util.retry import Retry
            
            # Retry strategy for connection issues
            retry_strategy = Retry(
                total=3,
                status_forcelist=[429, 500, 502, 503, 504],
                backoff_factor=1,
                allowed_methods=["POST"]
            )
            
            adapter = HTTPAdapter(max_retries=retry_strategy)
            session.mount("https://", adapter)
            
            with open(file_path, "rb") as audio_file:
                files = {
                    "file": (os.path.basename(file_path), audio_file, self._get_content_type(file_path))
                }
                data = {
                    "model": "whisper-1",
                    "response_format": "text"
                }
                
                # Make the request with improved SSL handling
                response = session.post(
                    self.base_url,
                    headers=headers,
                    files=files,
                    data=data,
                    timeout=(30, 120),  # (connect_timeout, read_timeout)
                    stream=False
                )
                
                if response.status_code == 200:
                    transcription = response.text.strip()
                    confidence = 0.9  # OpenAI doesn't provide confidence scores
                    logger.info(f"Transcription successful: {len(transcription)} characters")
                    return transcription, confidence
                else:
                    error_msg = f"OpenAI API error: {response.status_code} - {response.text}"
                    logger.error(error_msg)
                    raise Exception(error_msg)
                    
        except requests.exceptions.SSLError as e:
            error_msg = f"SSL Error (try updating urllib3 or certificates): {str(e)}"
            logger.error(error_msg)
            raise Exception(error_msg)
        except requests.exceptions.RequestException as e:
            error_msg = f"Request failed: {str(e)}"
            logger.error(error_msg)
            raise Exception(error_msg)
        except Exception as e:
            error_msg = f"Transcription failed: {str(e)}"
            logger.error(error_msg)
            raise Exception(error_msg)
    
    def _get_content_type(self, file_path: str) -> str:
        """Get appropriate content type for the file."""
        ext = Path(file_path).suffix.lower()
        
        # Audio formats
        if ext in ['.wav', '.wave']:
            return 'audio/wav'
        elif ext in ['.mp3']:
            return 'audio/mpeg'
        elif ext in ['.m4a']:
            return 'audio/mp4'
        elif ext in ['.flac']:
            return 'audio/flac'
        elif ext in ['.ogg']:
            return 'audio/ogg'
        
        # Video formats (OpenAI accepts these for audio extraction)
        elif ext in ['.mp4']:
            return 'video/mp4'
        elif ext in ['.mov']:
            return 'video/quicktime'
        elif ext in ['.avi']:
            return 'video/x-msvideo'
        elif ext in ['.mkv']:
            return 'video/x-matroska'
        
        # Default
        else:
            return 'application/octet-stream'
    
    def supports_file_type(self, file_path: str) -> bool:
        """Check if the file type is supported for transcription."""
        ext = Path(file_path).suffix.lower()
        supported_extensions = [
            # Audio formats
            '.wav', '.wave', '.mp3', '.m4a', '.flac', '.ogg',
            # Video formats (for audio extraction)
            '.mp4', '.mov', '.avi', '.mkv'
        ]
        return ext in supported_extensions


# Global transcription service instance
_transcription_service = None

def get_transcription_service(prefer_requests: bool = False) -> TranscriptionService:
    """
    Get a global transcription service instance.
    
    Args:
        prefer_requests: If True, use requests instead of OpenAI client even if available.
                        Useful for servers that don't want the openai dependency.
    """
    global _transcription_service
    if _transcription_service is None:
        _transcription_service = TranscriptionService(prefer_requests=prefer_requests)
    return _transcription_service

def reset_transcription_service():
    """Reset the global transcription service (for testing/configuration changes)."""
    global _transcription_service
    _transcription_service = None