"""
Top-level file system interface for percolate

This module provides a simple, unified interface for file operations across different storage systems.
Automatically detects the storage provider based on URI scheme and routes to appropriate handler.

Usage:
    import percolate as p8
    
    # Read files from any source
    content = p8.fs.read("local_file.txt")
    content = p8.fs.read("s3://bucket/file.pdf") 
    content = p8.fs.read("https://example.com/data.csv")
    
    # Write files to any destination
    p8.fs.write("output.txt", "Hello World")
    p8.fs.write("s3://bucket/output.json", data)
    
    # List files
    files = p8.fs.ls("s3://bucket/prefix/")
    files = p8.fs.ls("/local/directory/")
    
    # Open file-like objects
    with p8.fs.open("s3://bucket/file.txt", "r") as f:
        content = f.read()
"""

import os
import io
from pathlib import Path
from typing import Union, Any, List, BinaryIO, TextIO
from urllib.parse import urlparse
import requests
import tempfile

from percolate.services.FileSystemService import FileSystemService
from percolate.utils import logger


class PercolateFS:
    """
    Top-level file system interface that automatically routes to appropriate providers.
    
    Supports:
    - Local files: /path/to/file.txt
    - S3 files: s3://bucket/path/to/file.txt
    - HTTP(S) files: https://example.com/file.txt (read-only)
    """
    
    def __init__(self):
        self._fs_service = None
        self._aws_fs_service = None
    
    @property
    def fs_service(self) -> FileSystemService:
        """Get or create the default FileSystemService instance"""
        if self._fs_service is None:
            self._fs_service = FileSystemService()
        return self._fs_service
    
    @property
    def aws_fs_service(self) -> FileSystemService:
        """Get or create the AWS FileSystemService instance"""
        if self._aws_fs_service is None:
            self._aws_fs_service = FileSystemService()
        return self._aws_fs_service
    
    def _get_service(self, path: str) -> FileSystemService:
        """Determine which FileSystemService to use based on path and environment"""
        if not path.startswith('s3://'):
            return self.fs_service
        
        # For S3 paths, check if we should use AWS mode
        # Use AWS mode if AWS credentials are available and no custom S3 credentials
        has_aws_creds = bool(os.environ.get("AWS_ACCESS_KEY_ID") and os.environ.get("AWS_SECRET_ACCESS_KEY"))
        has_custom_s3_creds = bool(os.environ.get("S3_ACCESS_KEY") and os.environ.get("S3_SECRET"))
        
        if has_aws_creds and not has_custom_s3_creds:
            return self.aws_fs_service
        else:
            return self.fs_service
    
    def _is_http_url(self, path: str) -> bool:
        """Check if path is an HTTP(S) URL"""
        return path.startswith(('http://', 'https://'))
    
    def _download_http_to_temp(self, url: str) -> str:
        """Download HTTP(S) URL to temporary file and return path"""
        try:
            response = requests.get(url, stream=True)
            response.raise_for_status()
            
            # Determine file extension from URL or Content-Type
            parsed = urlparse(url)
            filename = Path(parsed.path).name
            if not filename or '.' not in filename:
                content_type = response.headers.get('Content-Type', '')
                if 'json' in content_type:
                    filename = 'download.json'
                elif 'csv' in content_type:
                    filename = 'download.csv'
                elif 'pdf' in content_type:
                    filename = 'download.pdf'
                elif 'image' in content_type:
                    filename = 'download.jpg'
                else:
                    filename = 'download.bin'
            
            # Create temporary file
            temp_file = tempfile.NamedTemporaryFile(delete=False, suffix=f"_{filename}")
            temp_path = temp_file.name
            
            # Download content
            for chunk in response.iter_content(chunk_size=8192):
                temp_file.write(chunk)
            
            temp_file.close()
            logger.info(f"Downloaded {url} to temporary file {temp_path}")
            return temp_path
            
        except Exception as e:
            logger.error(f"Failed to download {url}: {e}")
            raise
    
    def read(self, path: str, **kwargs) -> Any:
        """
        Read a file from any supported source.
        
        Args:
            path: File path, S3 URI, or HTTP(S) URL
            **kwargs: Additional arguments passed to the file handler
            
        Returns:
            Parsed content based on file type (str, PIL.Image, polars.DataFrame, etc.)
            
        Examples:
            # Local file
            content = p8.fs.read("/path/to/file.txt")
            
            # S3 file (automatically uses AWS or custom S3 based on credentials)
            df = p8.fs.read("s3://bucket/data.csv")
            
            # HTTP download and parse
            data = p8.fs.read("https://api.example.com/data.json")
        """
        logger.info(f"Reading file: {path}")
        
        if self._is_http_url(path):
            # Download HTTP(S) file to temporary location and read
            temp_path = self._download_http_to_temp(path)
            try:
                return self.fs_service.read(temp_path, **kwargs)
            finally:
                # Clean up temporary file
                try:
                    os.unlink(temp_path)
                except:
                    pass
        else:
            # Use appropriate file system service
            service = self._get_service(path)
            return service.read(path, **kwargs)
    
    def read_bytes(self, path: str) -> bytes:
        """
        Read a file as raw bytes from any supported source.
        
        Args:
            path: File path, S3 URI, or HTTP(S) URL
            
        Returns:
            Raw file content as bytes
            
        Examples:
            # Read any file as bytes
            data = p8.fs.read_bytes("s3://bucket/file.zip")
            data = p8.fs.read_bytes("https://example.com/image.png")
        """
        logger.info(f"Reading bytes: {path}")
        
        if self._is_http_url(path):
            # Download HTTP(S) file directly to bytes
            response = requests.get(path)
            response.raise_for_status()
            return response.content
        else:
            service = self._get_service(path)
            return service.read_bytes(path)
    
    def write(self, path: str, data: Any, **kwargs) -> None:
        """
        Write data to a file.
        
        Args:
            path: File path or S3 URI (HTTP(S) not supported for writing)
            data: Data to write (type depends on file format)
            **kwargs: Additional arguments passed to the file handler
            
        Examples:
            # Write text
            p8.fs.write("output.txt", "Hello World")
            
            # Write DataFrame to S3
            p8.fs.write("s3://bucket/data.csv", df)
            
            # Write image
            p8.fs.write("image.png", pil_image)
        """
        if self._is_http_url(path):
            raise ValueError("Writing to HTTP(S) URLs is not supported")
        
        logger.info(f"Writing file: {path}")
        service = self._get_service(path)
        service.write(path, data, **kwargs)
    
    def open(self, path: str, mode: str = 'r', **kwargs) -> Union[BinaryIO, TextIO]:
        """
        Open a file-like object for reading or writing.
        
        Args:
            path: File path or S3 URI
            mode: File mode ('r', 'rb', 'w', 'wb')
            **kwargs: Additional arguments
            
        Returns:
            File-like object
            
        Examples:
            # Read text file
            with p8.fs.open("file.txt", "r") as f:
                content = f.read()
            
            # Write to S3
            with p8.fs.open("s3://bucket/output.txt", "w") as f:
                f.write("Hello S3")
            
            # Read binary from HTTP
            with p8.fs.open("https://example.com/file.zip", "rb") as f:
                data = f.read()
        """
        if self._is_http_url(path):
            if 'w' in mode:
                raise ValueError("Writing to HTTP(S) URLs is not supported")
            
            # For HTTP URLs, download to temporary file and return file object
            temp_path = self._download_http_to_temp(path)
            
            # Return a file object that cleans up the temp file when closed
            class HTTPFileWrapper:
                def __init__(self, temp_path: str, mode: str):
                    self.temp_path = temp_path
                    self.file = open(temp_path, mode)
                
                def __enter__(self):
                    return self.file
                
                def __exit__(self, exc_type, exc_val, exc_tb):
                    self.file.close()
                    try:
                        os.unlink(self.temp_path)
                    except:
                        pass
                
                def __getattr__(self, name):
                    return getattr(self.file, name)
            
            return HTTPFileWrapper(temp_path, mode)
        
        # For local/S3 files, delegate to the appropriate service
        if path.startswith('s3://'):
            service = self._get_service(path)
            # S3Service doesn't have open method, so we need to implement basic functionality
            if 'r' in mode:
                # For reading, download content and wrap in BytesIO/StringIO
                content = service.read_bytes(path)
                if 'b' in mode:
                    return io.BytesIO(content)
                else:
                    text_content = content.decode(kwargs.get('encoding', 'utf-8'))
                    return io.StringIO(text_content)
            else:
                # For writing, return a wrapper that writes to S3 on close
                class S3FileWrapper:
                    def __init__(self, path: str, service: FileSystemService, mode: str):
                        self.path = path
                        self.service = service
                        self.mode = mode
                        self.buffer = io.BytesIO() if 'b' in mode else io.StringIO()
                    
                    def __enter__(self):
                        return self.buffer
                    
                    def __exit__(self, exc_type, exc_val, exc_tb):
                        content = self.buffer.getvalue()
                        if isinstance(content, str):
                            content = content.encode('utf-8')
                        self.service.write(self.path, content)
                    
                    def __getattr__(self, name):
                        return getattr(self.buffer, name)
                
                return S3FileWrapper(path, service, mode)
        else:
            # Local file
            return open(path, mode, **kwargs)
    
    def ls(self, path: str, **kwargs) -> List[str]:
        """
        List files and directories.
        
        Args:
            path: Directory path or S3 prefix
            **kwargs: Additional arguments
            
        Returns:
            List of file/directory paths
            
        Examples:
            # List local directory
            files = p8.fs.ls("/path/to/directory/")
            
            # List S3 prefix
            files = p8.fs.ls("s3://bucket/prefix/")
        """
        if self._is_http_url(path):
            raise ValueError("Listing HTTP(S) URLs is not supported")
        
        logger.info(f"Listing: {path}")
        
        if path.startswith('s3://'):
            # For S3, we need to use the S3Service directly since FileSystemService doesn't have ls
            service = self._get_service(path)
            if hasattr(service, '_get_provider'):
                provider = service._get_provider(path)
                if hasattr(provider, 's3_service'):
                    # Parse S3 URI to get project and prefix
                    parsed = provider.s3_service.parse_s3_uri(path)
                    bucket = parsed["bucket"] 
                    prefix = parsed["key"]
                    
                    # Use list_files method but need to adapt the interface
                    # This is a simplified approach - in practice you might want to enhance this
                    try:
                        # Try to extract project name from prefix
                        if '/' in prefix:
                            project = prefix.split('/')[0]
                            subprefix = '/'.join(prefix.split('/')[1:]) if len(prefix.split('/')) > 1 else None
                        else:
                            project = prefix
                            subprefix = None
                        
                        files = provider.s3_service.list_files(project, subprefix)
                        return [f"s3://{bucket}/{f['key']}" for f in files]
                    except:
                        # Fallback - return empty list or implement different approach
                        logger.warning(f"Could not list S3 path: {path}")
                        return []
            return []
        else:
            # Local directory
            path_obj = Path(path)
            if path_obj.is_dir():
                return [str(p) for p in path_obj.iterdir()]
            else:
                return [str(path_obj)] if path_obj.exists() else []
    
    def exists(self, path: str) -> bool:
        """
        Check if a file or directory exists.
        
        Args:
            path: File path, S3 URI, or HTTP(S) URL
            
        Returns:
            True if the file exists, False otherwise
            
        Examples:
            # Check local file
            if p8.fs.exists("/path/to/file.txt"):
                content = p8.fs.read("/path/to/file.txt")
            
            # Check S3 file
            if p8.fs.exists("s3://bucket/file.pdf"):
                process_file("s3://bucket/file.pdf")
            
            # Check HTTP URL
            if p8.fs.exists("https://api.example.com/data.json"):
                data = p8.fs.read("https://api.example.com/data.json")
        """
        if self._is_http_url(path):
            try:
                response = requests.head(path)
                return response.status_code == 200
            except:
                return False
        else:
            service = self._get_service(path)
            return service.exists(path)
    
    def copy(self, source_path: str, dest_path: str, **kwargs) -> None:
        """
        Copy a file from source to destination.
        
        Args:
            source_path: Source file path, S3 URI, or HTTP(S) URL
            dest_path: Destination file path or S3 URI
            **kwargs: Additional arguments
            
        Examples:
            # Copy local to S3
            p8.fs.copy("local_file.txt", "s3://bucket/remote_file.txt")
            
            # Copy S3 to local
            p8.fs.copy("s3://bucket/file.pdf", "local_copy.pdf")
            
            # Copy HTTP to S3
            p8.fs.copy("https://example.com/data.csv", "s3://bucket/downloaded_data.csv")
        """
        logger.info(f"Copying: {source_path} -> {dest_path}")
        
        # If source is HTTP, download first
        if self._is_http_url(source_path):
            if self._is_http_url(dest_path):
                raise ValueError("Cannot copy from HTTP to HTTP")
            
            # Download and write to destination
            content = self.read_bytes(source_path)
            self.write(dest_path, content)
        else:
            # Use the FileSystemService copy method
            source_service = self._get_service(source_path)
            source_service.copy(source_path, dest_path, **kwargs)
    
    def get_file_info(self, path: str) -> dict:
        """
        Get information about a file.
        
        Args:
            path: File path, S3 URI, or HTTP(S) URL
            
        Returns:
            Dictionary with file information
            
        Examples:
            info = p8.fs.get_file_info("s3://bucket/file.pdf")
            print(f"File size: {info.get('size', 'unknown')}")
            print(f"Content type: {info.get('mime_type', 'unknown')}")
        """
        if self._is_http_url(path):
            try:
                response = requests.head(path)
                return {
                    'exists': response.status_code == 200,
                    'path': path,
                    'storage_type': 'http',
                    'content_type': response.headers.get('Content-Type'),
                    'size': response.headers.get('Content-Length'),
                    'has_handler': False,
                    'handler_type': None
                }
            except Exception as e:
                return {
                    'exists': False,
                    'path': path,
                    'storage_type': 'http',
                    'error': str(e)
                }
        else:
            service = self._get_service(path)
            return service.get_file_info(path)


# Create a singleton instance for use as p8.fs
fs = PercolateFS()