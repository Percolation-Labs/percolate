"""
S3 Service for managing object storage with AWS and custom S3 providers.

This service provides functionality for:
1. Creating user-specific access keys with limited permissions
2. Managing files (upload, download, list) in buckets and subfolders
3. Supporting runtime contexts with access to different buckets
4. Automatic fallback to AWS when custom S3 variables are not set
"""

import os
import boto3
import uuid
from typing import List, Dict, Any, Optional, BinaryIO, Union
from botocore.exceptions import ClientError
from percolate.utils import logger
import typing
from io import BytesIO
from datetime import datetime


def _resolve_aws_env() -> Dict[str, Optional[str]]:
    """
    Resolve AWS environment variables.
    When using AWS, we rely on boto3's default credential resolution.
    """
    return {
        'access_key': os.environ.get("AWS_ACCESS_KEY_ID"),
        'secret_key': os.environ.get("AWS_SECRET_ACCESS_KEY"),
        'endpoint_url': None,  # AWS uses default endpoints
        'bucket': os.environ.get("S3_DEFAULT_BUCKET", os.environ.get("S3_BUCKET_NAME", "percolate"))
    }


def _resolve_custom_s3_env() -> Dict[str, Optional[str]]:
    """
    Resolve custom S3 environment variables for non-AWS providers (Hetzner, MinIO, etc.).
    Only use these when we're explicitly not using AWS.
    """
    return {
        'access_key': os.environ.get("S3_ACCESS_KEY"),
        'secret_key': os.environ.get("S3_SECRET"),
        'endpoint_url': os.environ.get("S3_URL"),
        'bucket': os.environ.get("S3_DEFAULT_BUCKET", os.environ.get("S3_BUCKET_NAME", "percolate"))
    }


def _should_use_aws() -> bool:
    """
    Determine if we should use AWS S3 based on environment configuration.
    
    Logic:
    1. If P8_USE_AWS_S3 is explicitly set, use that value
    2. If ALL custom S3 environment variables (S3_ACCESS_KEY, S3_SECRET) are set, use custom S3
    3. Otherwise, default to AWS (let boto3 handle credentials or complain if it can't)
    """
    # Explicit override takes precedence
    use_aws_env = os.environ.get('P8_USE_AWS_S3', '').lower()
    if use_aws_env in ['true', '1', 'yes']:
        return True
    elif use_aws_env in ['false', '0', 'no']:
        return False
    
    # Auto-detection: only use custom S3 if we have the required credentials
    custom_env = _resolve_custom_s3_env()
    has_custom_credentials = bool(
        custom_env['access_key'] and 
        custom_env['secret_key']
    )
    
    if has_custom_credentials:
        return False
    
    # Default to AWS - let boto3 handle whether credentials are available
    return True


def _get_s3_config(use_aws: bool) -> Dict[str, Any]:
    """
    Get the complete S3 configuration based on whether we're using AWS or not.
    """
    if use_aws:
        env_config = _resolve_aws_env()
        
        # For AWS, we typically don't need to specify credentials explicitly
        # as boto3 will use the default credential chain
        config = {
            'credentials': {
                'access_key': env_config['access_key'],  # May be None - boto3 will handle it
                'secret_key': env_config['secret_key'],  # May be None - boto3 will handle it
            },
            'endpoint_url': None,  # AWS uses default endpoints
            'bucket': env_config['bucket'],
            'boto3_config': boto3.session.Config(
                signature_version='s3v4',
                s3={'addressing_style': 'virtual'}
            ),
            'provider_type': 'aws'
        }
    else:
        env_config = _resolve_custom_s3_env()
        
        # For custom S3, we must have credentials, but S3_URL is optional
        # (some services might work with default S3 endpoints)
        if not env_config['access_key'] or not env_config['secret_key']:
            raise ValueError(
                "Custom S3 configuration requires both S3_ACCESS_KEY and S3_SECRET environment variables."
            )
        
        # Use provided endpoint URL or None (some custom S3 services work with default endpoints)
        endpoint_url = env_config['endpoint_url']
        if endpoint_url and not endpoint_url.startswith("http"):
            endpoint_url = f"https://{endpoint_url}"
        
        # For custom S3 providers, try to add checksum calculation settings
        # These are important for non-AWS providers but may not be supported in all boto3 versions
        boto3_config_kwargs = {
            'signature_version': 's3v4',
            's3': {'addressing_style': 'path'}
        }
        
        # Try to add checksum settings for custom S3 providers (Hetzner, MinIO, etc.)
        try:
            boto3_config_kwargs.update({
                'request_checksum_calculation': "when_required", 
                'response_checksum_validation': "when_required"
            })
            boto3_config = boto3.session.Config(**boto3_config_kwargs)
        except TypeError:
            # Fallback for older boto3 versions that don't support these parameters
            logger.warning("boto3 version doesn't support checksum calculation parameters, using basic config")
            boto3_config = boto3.session.Config(
                signature_version='s3v4',
                s3={'addressing_style': 'path'}
            )
        
        config = {
            'credentials': {
                'access_key': env_config['access_key'],
                'secret_key': env_config['secret_key'],
            },
            'endpoint_url': endpoint_url,
            'bucket': env_config['bucket'],
            'boto3_config': boto3_config,
            'provider_type': 'custom'
        }
    
    return config

class FileLikeWritable:
    """
    A file-like object wrapper for S3 uploads.
    
    This class provides a file-like interface for writing to S3 objects.
    It accumulates the data in memory and then uploads it to S3 when closed.
    
    Usage:
    ```
    with s3_service.open("s3://bucket/key", "wb") as f:
        f.write(b"Hello, World!")
    ```
    """
    
    def __init__(self, s3_client, bucket: str, key: str):
        """
        Initialize a file-like object for writing to S3.
        
        Args:
            s3_client: The boto3 S3 client
            bucket: The S3 bucket name
            key: The S3 object key
        """
        self.s3_client = s3_client
        self.bucket = bucket
        self.key = key
        self.buffer = BytesIO()
        self.closed = False
        self.name = key.split('/')[-1] if '/' in key else key
        self.mode = 'wb'
        self.uri = f"s3://{bucket}/{key}"
        
    def write(self, data: Union[bytes, str]) -> int:
        """
        Write data to the buffer.
        
        Args:
            data: The data to write (bytes or string)
            
        Returns:
            Number of bytes written
        """
        if self.closed:
            raise ValueError("I/O operation on closed file")
            
        if isinstance(data, str):
            data = data.encode('utf-8')
            
        return self.buffer.write(data)
    
    def seek(self, offset: int, whence: int = 0) -> int:
        """
        Change the stream position to the given offset.
        
        Args:
            offset: The offset relative to the position indicated by whence
            whence: How to interpret the offset (0=start, 1=current, 2=end)
            
        Returns:
            The new absolute position
        """
        if self.closed:
            raise ValueError("I/O operation on closed file")
        return self.buffer.seek(offset, whence)
    
    def tell(self) -> int:
        """
        Return the current stream position.
        
        Returns:
            The current position
        """
        if self.closed:
            raise ValueError("I/O operation on closed file")
        return self.buffer.tell()
    
    def read(self, size: int = -1) -> bytes:
        """
        Read data from the buffer (dummy implementation for compatibility).
        
        Args:
            size: The number of bytes to read
            
        Returns:
            Empty bytes object - this is a write-only stream
            
        Raises:
            ValueError: Always raised - this is a write-only stream
        """
        raise ValueError("File not open for reading")
        
    def close(self) -> None:
        """
        Close the file-like object and upload the data to S3.
        """
        if self.closed:
            return
            
        self.buffer.seek(0)
        
        try:
            # Upload the data to S3
            self.s3_client.put_object(
                Bucket=self.bucket,
                Key=self.key,
                Body=self.buffer.read()
            )
            logger.info(f"Successfully uploaded data to s3://{self.bucket}/{self.key}")
        except Exception as e:
            logger.error(f"Error uploading data to s3://{self.bucket}/{self.key}: {e}")
            raise
        finally:
            self.buffer.close()
            self.closed = True
    
    def flush(self) -> None:
        """
        Flush the write buffer (no-op for in-memory buffer).
        """
        if self.closed:
            raise ValueError("I/O operation on closed file")
        self.buffer.flush()
        
    def readable(self) -> bool:
        """Check if the stream is readable."""
        return False
    
    def writable(self) -> bool:
        """Check if the stream is writable."""
        return not self.closed
    
    def seekable(self) -> bool:
        """Check if the stream is seekable."""
        return not self.closed
        
    def __enter__(self):
        """Support for context manager protocol."""
        return self
        
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Support for context manager protocol."""
        self.close()


class S3Service:
    """
    Simplified S3 Service with cleaner AWS vs non-AWS configuration.
    
    Configuration Logic:
        1. If P8_USE_AWS_S3 is explicitly set ('true'/'false'), use that
        2. If S3_ACCESS_KEY, S3_SECRET, and S3_URL are all set, use custom S3
        3. Otherwise, default to AWS S3 (assuming that's the user's intention)
    
    Environment Variables:
        P8_USE_AWS_S3: Explicitly control S3 provider ('true' for AWS, 'false' for custom)
        
        For AWS S3 (default when custom S3 vars not set):
            AWS_ACCESS_KEY_ID: AWS access key (optional - boto3 will use credential chain)
            AWS_SECRET_ACCESS_KEY: AWS secret key (optional - boto3 will use credential chain)
            S3_DEFAULT_BUCKET: S3 bucket name (default: 'percolate')
            
        For Custom S3 (Hetzner, MinIO, etc.):
            S3_ACCESS_KEY: Custom S3 access key (required for custom S3)
            S3_SECRET: Custom S3 secret key (required for custom S3)
            S3_URL: Custom S3 endpoint URL (required for custom S3)
            S3_DEFAULT_BUCKET: S3 bucket name (default: 'percolate')
    """
    
    def __init__(self, 
                 access_key: str = None, 
                 secret_key: str = None, 
                 endpoint_url: str = None
                 ):
        """
        Initialize the S3 service with simplified configuration.
        
        Args:
            access_key: S3 access key (optional - will use environment)
            secret_key: S3 secret key (optional - will use environment)
            endpoint_url: S3 endpoint URL (optional - will use environment)
        """
        
        # Determine if we should use AWS based on environment
        self.use_aws = _should_use_aws()
        
        logger.trace(f"Initializing S3Service: {'AWS' if self.use_aws else 'Custom S3'} mode")
        
        # Get configuration from environment
        env_config = _get_s3_config(self.use_aws)
        
        # Override with provided parameters
        self.access_key = access_key or env_config['credentials']['access_key']
        self.secret_key = secret_key or env_config['credentials']['secret_key']
        self.endpoint_url = endpoint_url or env_config['endpoint_url']
        self.default_bucket = env_config['bucket']
        self.provider_type = env_config['provider_type']
        
        # For AWS, allow boto3 to handle credentials if not explicitly provided
        if self.use_aws and not (self.access_key and self.secret_key):
            logger.info("Using boto3 default credential chain for AWS")
            client_kwargs = {}
        else:
            # Validate credentials are available
            if not self.access_key or not self.secret_key:
                if self.use_aws:
                    raise ValueError(
                        "AWS credentials not found. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, "
                        "or configure AWS credentials using boto3 default methods "
                        "(IAM roles, credential files, etc.)"
                    )
                else:
                    raise ValueError(
                        "Custom S3 credentials must be provided via S3_ACCESS_KEY and S3_SECRET "
                        "environment variables or constructor parameters"
                    )
            
            client_kwargs = {
                'aws_access_key_id': self.access_key,
                'aws_secret_access_key': self.secret_key,
            }
        
        # Add endpoint URL for custom S3 providers
        if self.endpoint_url:
            client_kwargs['endpoint_url'] = self.endpoint_url
        
        # Add configuration
        client_kwargs['config'] = env_config['boto3_config']
        
        # Create S3 client
        self.s3_client = boto3.client('s3', **client_kwargs)
        
        # Create IAM client (primarily for AWS, may not work with all custom providers)
        self._setup_iam_client(client_kwargs)
        
        logger.trace(f"S3Service initialized successfully: bucket='{self.default_bucket}', "
                   f"provider='{self.provider_type}', endpoint='{self.endpoint_url or 'default'}'")
    
    def _setup_iam_client(self, base_client_kwargs: Dict[str, Any]):
        """Setup IAM client for access key management (primarily for AWS)."""
        try:
            iam_kwargs = base_client_kwargs.copy()
            
            # Remove S3-specific config for IAM
            if 'config' in iam_kwargs:
                del iam_kwargs['config']
            
            # For custom S3 providers, IAM operations may not be supported
            if not self.use_aws and self.endpoint_url:
                # Try to use the same endpoint for IAM (may not work)
                iam_kwargs['endpoint_url'] = self.endpoint_url
                iam_kwargs['config'] = boto3.session.Config(
                    signature_version='s3',
                    s3={'addressing_style': 'path'}
                )
            
            self.iam_client = boto3.client('iam', **iam_kwargs)
            
        except Exception as e:
            logger.warning(f"Failed to initialize IAM client: {e}. IAM operations will not be available.")
            self.iam_client = None
    
    def get_configuration_info(self) -> Dict[str, Any]:
        """
        Get information about the current S3 configuration.
        Useful for debugging and verification.
        """
        return {
            'provider_type': self.provider_type,
            'use_aws': self.use_aws,
            'endpoint_url': self.endpoint_url,
            'default_bucket': self.default_bucket,
            'has_credentials': bool(self.access_key and self.secret_key),
            'iam_available': self.iam_client is not None,
            'environment_variables': {
                'P8_USE_AWS_S3': os.environ.get('P8_USE_AWS_S3'),
                'AWS_ACCESS_KEY_ID': '***' if os.environ.get('AWS_ACCESS_KEY_ID') else None,
                'AWS_SECRET_ACCESS_KEY': '***' if os.environ.get('AWS_SECRET_ACCESS_KEY') else None,
                'S3_ACCESS_KEY': '***' if os.environ.get('S3_ACCESS_KEY') else None,
                'S3_SECRET': '***' if os.environ.get('S3_SECRET') else None,
                'S3_URL': os.environ.get('S3_URL'),
                'S3_DEFAULT_BUCKET': os.environ.get('S3_DEFAULT_BUCKET'),
            }
        }
    
    def _validate_connection(self):
        """Validate the S3 connection by attempting a simple operation."""
        try:
            # Test the connection with a head_bucket operation
            self.s3_client.head_bucket(Bucket=self.default_bucket)
            logger.debug(f"S3 connection validated successfully for bucket: {self.default_bucket}")
        except ClientError as e:
            error_code = e.response['Error']['Code']
            if error_code == '404':
                raise ValueError(f"Bucket '{self.default_bucket}' not found")
            elif error_code == '403':
                raise ValueError(f"Access denied to bucket '{self.default_bucket}'. Check S3 credentials.")
            else:
                logger.error(f"Failed to validate S3 connection: {str(e)}")
                raise
    
    def create_user_key(self, 
                        project_name: str, 
                        read_only: bool = False) -> Dict[str, str]:
        """
        Create a new access key for a specific project subfolder.
        
        Args:
            project_name: The project name (used as subfolder name)
            read_only: If True, create a read-only key
            
        Returns:
            Dict containing the new access_key and secret_key
        """
        try:
            # Create a policy that restricts access to the project subfolder
            policy_document = {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:ListBucket"
                        ],
                        "Resource": [
                            f"arn:aws:s3:::{self.default_bucket}"
                        ],
                        "Condition": {
                            "StringLike": {
                                "s3:prefix": [
                                    f"{project_name}/*"
                                ]
                            }
                        }
                    }
                ]
            }
            
            # Add read/write permissions if not read-only
            if read_only:
                policy_document["Statement"].append({
                    "Effect": "Allow",
                    "Action": [
                        "s3:GetObject"
                    ],
                    "Resource": [
                        f"arn:aws:s3:::{self.default_bucket}/{project_name}/*"
                    ]
                })
            else:
                policy_document["Statement"].append({
                    "Effect": "Allow",
                    "Action": [
                        "s3:GetObject",
                        "s3:PutObject",
                        "s3:DeleteObject"
                    ],
                    "Resource": [
                        f"arn:aws:s3:::{self.default_bucket}/{project_name}/*"
                    ]
                })
            
            policy_name = f"project-{project_name}-{uuid.uuid4().hex[:8]}"
            
            # Create the policy
            response = self.iam_client.create_policy(
                PolicyName=policy_name,
                PolicyDocument=str(policy_document)
            )
            
            policy_arn = response['Policy']['Arn']
            
            # Create access key with the policy attached
            response = self.iam_client.create_access_key()
            
            # Store the association between the key and policy
            # Note: In production, you would persist this to database
            
            return {
                "access_key": response['AccessKey']['AccessKeyId'],
                "secret_key": response['AccessKey']['SecretAccessKey'],
                "policy_arn": policy_arn,
                "project": project_name,
                "read_only": read_only
            }
            
        except ClientError as e:
            logger.error(f"Error creating user key: {str(e)}")
            # Handle common S3 errors
            if "NoSuchBucket" in str(e):
                raise ValueError(f"Bucket {self.default_bucket} does not exist")
            raise
    
    def list_files(self, 
                   project_name: str, 
                   prefix: str = None) -> List[Dict[str, Any]]:
        """
        List files in the project subfolder.
        
        Args:
            project_name: The project name (used as subfolder name)
            prefix: Optional additional prefix within the project folder
            
        Returns:
            List of file metadata dictionaries
        """
        try:
            # Construct the full prefix
            full_prefix = f"{project_name}/"
            if prefix:
                # Ensure prefix doesn't start with '/' and ends with '/'
                prefix = prefix.strip('/')
                if prefix:
                    full_prefix += f"{prefix}/"
            logger.debug(f"Listing files {self.default_bucket=}, {full_prefix=}")
            
            response = self.s3_client.list_objects_v2(
                Bucket=self.default_bucket,
                Prefix=full_prefix
            )
            
            # Format the results
            files = []
            if 'Contents' in response:
                for obj in response['Contents']:
                    # Extract the filename from the key by removing the prefix
                    key = obj['Key']
                    name = key[len(full_prefix):] if key.startswith(full_prefix) else key
                    
                    files.append({
                        "key": key,
                        "name": name,
                        "size": obj['Size'],
                        "last_modified": obj['LastModified'].isoformat(),
                        "etag": obj['ETag'].strip('"')
                    })
            
            return files
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_message = str(e)
            
            if error_code == 'SignatureDoesNotMatch':
                logger.error(f"S3 signature mismatch. Current signature version: {self.s3_client._client_config.signature_version}. Try using 's3v4' instead.")
                raise ValueError(f"S3 signature mismatch error: {error_message}")
            elif error_code == 'NoSuchBucket':
                logger.error(f"Bucket '{self.default_bucket}' does not exist")
                raise ValueError(f"Bucket '{self.default_bucket}' does not exist")
            else:
                logger.error(f"Error listing files: {error_message}")
                raise
    
    def create_s3_uri(self, project_name: str = None, file_name: str = None, prefix: str = None) -> str:
        """
        Create an S3 URI from components.
        
        Args:
            project_name: The project name
            file_name: The file name
            prefix: Optional additional prefix
            
        Returns:
            S3 URI in the format s3://bucket_name/project_name/prefix/file_name
        """
        # Start with the bucket
        uri = f"s3://{self.default_bucket}/"
        
        # Add project name if provided
        if project_name:
            uri += f"{project_name}/"
        
        # Add prefix if provided
        if prefix:
            # Ensure prefix doesn't start with '/' and ends with '/'
            prefix = prefix.strip('/')
            if prefix:
                uri += f"{prefix}/"
        
        # Add file name if provided
        if file_name:
            uri += file_name
            
        return uri
        
    def upload_filebytes_to_uri(self, 
                               s3_uri: str,
                               file_content: typing.Union[BinaryIO, bytes],
                               content_type: str = None
                               ) -> Dict[str, Any]:
        """
        Upload file bytes or file-like object to a specific S3 URI.
        
        Args:
            s3_uri: The S3 URI to upload to
            file_content: The file content (bytes or file-like object)
            content_type: Optional MIME type
            
        Returns:
            Dict with upload status and file metadata
        """
        try:
            # Parse the URI
            parsed = self.parse_s3_uri(s3_uri)
            bucket_name = parsed["bucket"]
            object_key = parsed["key"]
            
            # Prepare parameters for put_object
            # If file_content is a file object, ensure it's at the beginning
            if hasattr(file_content, 'seek'):
                file_content.seek(0)
            
            put_params = {
                'Bucket': bucket_name,
                'Key': object_key,
                'Body': file_content
            }
            
            # Add content type if provided
            if content_type:
                put_params['ContentType'] = content_type
                
            logger.debug(f"Uploading file bytes to {s3_uri}")
            
            # Try regular upload first
            try:
                response = self.s3_client.put_object(**put_params)
                
            except ClientError as e:
                error_code = e.response.get('Error', {}).get('Code')
                error_message = str(e)
                
                # Check if it's a SHA256 mismatch error
                if error_code in ['XAmzContentSHA256Mismatch', 'BadDigest'] or 'SHA256' in error_message:
                    logger.warning(f"SHA256 mismatch detected in put_object, falling back to presigned POST: {error_message}")
                    
                    # Use presigned POST as fallback
                    self._upload_bytes_presigned_post(
                        file_content=file_content,
                        bucket_name=bucket_name,
                        object_key=object_key,
                        content_type=content_type
                    )
                    
                    logger.info(f"Successfully uploaded to {s3_uri} using presigned POST fallback")
                else:
                    # Re-raise if it's not a SHA256 error
                    raise
            
            # Get the uploaded file's metadata
            head_response = self.s3_client.head_object(
                Bucket=bucket_name,
                Key=object_key
            )
            
            # Get filename from the object key
            file_name = object_key.split('/')[-1] if '/' in object_key else object_key
            
            return {
                "uri": s3_uri,
                "name": file_name,
                "size": head_response.get('ContentLength', 0),
                "content_type": head_response.get('ContentType', 'application/octet-stream'),
                "last_modified": head_response.get('LastModified').isoformat() if 'LastModified' in head_response else None,
                "etag": head_response.get('ETag', '').strip('"'),
                "status": "success"
            }
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_message = str(e)
            
            if error_code == 'SignatureDoesNotMatch':
                logger.error(f"S3 signature mismatch during upload. Try using 's3v4' signature version.")
                raise ValueError(f"S3 signature mismatch error: {error_message}")
            elif error_code == 'NoSuchBucket':
                logger.error(f"Bucket '{bucket_name}' does not exist")
                raise ValueError(f"Bucket '{bucket_name}' does not exist")
            elif error_code == 'InvalidAccessKeyId':
                logger.error("Invalid S3 access key ID")
                raise ValueError("Invalid S3 access key ID. Check your S3_ACCESS_KEY environment variable.")
            else:
                logger.error(f"Error uploading file to {s3_uri}: {error_message}")
                raise
    
    def upload_file_to_uri(self,
                          s3_uri: str,
                          file_path_or_content: typing.Union[str, BinaryIO, bytes],
                          content_type: str = None) -> Dict[str, Any]:
        """
        Upload a file to a specific S3 URI from file path or content.
        
        Args:
            s3_uri: The S3 URI to upload to
            file_path_or_content: File path string, bytes, or file-like object
            content_type: Optional MIME type
            
        Returns:
            Dict with upload status and file metadata
        """
        if isinstance(file_path_or_content, str):
            # It's a file path - use streaming upload
            return self.upload_file_stream_to_uri(s3_uri, file_path_or_content, content_type)
        else:
            # It's bytes or file object - use the bytes upload
            return self.upload_filebytes_to_uri(s3_uri, file_path_or_content, content_type)
    
    def upload_file_stream_to_uri(self,
                                  s3_uri: str,
                                  file_path: str,
                                  content_type: str = None) -> Dict[str, Any]:
        """
        Upload a file to S3 using streaming (memory-friendly) for large files.
        
        Args:
            s3_uri: The S3 URI to upload to
            file_path: Path to the file on disk
            content_type: Optional MIME type
            
        Returns:
            Dict with upload status and file metadata
        """
        try:
            # Parse the URI
            parsed = self.parse_s3_uri(s3_uri)
            bucket_name = parsed["bucket"]
            object_key = parsed["key"]
            
            # Get file size
            file_size = os.path.getsize(file_path)
            
            # Determine content type if not provided
            if not content_type:
                import mimetypes
                content_type, _ = mimetypes.guess_type(file_path)
                if not content_type:
                    content_type = 'application/octet-stream'
            
            logger.debug(f"Streaming upload of {file_path} ({file_size} bytes) to {s3_uri}")
            
            # Try regular upload first
            try:
                self.s3_client.upload_file(
                    Filename=file_path,
                    Bucket=bucket_name,
                    Key=object_key,
                    ExtraArgs={'ContentType': content_type}
                )
                logger.debug(f"Regular upload successful for {file_path}")
                
            except ClientError as e:
                error_code = e.response.get('Error', {}).get('Code')
                error_message = str(e)
                
                # Check if it's a SHA256 mismatch error
                if error_code in ['XAmzContentSHA256Mismatch', 'BadDigest'] or 'SHA256' in error_message:
                    logger.warning(f"SHA256 mismatch detected, falling back to presigned upload: {error_message}")
                    
                    # Use presigned PUT as fallback
                    self._upload_file_presigned_put(
                        file_path=file_path,
                        bucket_name=bucket_name,
                        object_key=object_key,
                        content_type=content_type
                    )
                    
                    logger.info(f"Successfully uploaded {file_path} using presigned PUT fallback")
                else:
                    # Re-raise if it's not a SHA256 error
                    raise
            
            head_response = self.s3_client.head_object(
                Bucket=bucket_name,
                Key=object_key
            )
            
            # Get filename from the object key
            file_name = object_key.split('/')[-1] if '/' in object_key else object_key
            
            return {
                "uri": s3_uri,
                "name": file_name,
                "size": head_response.get('ContentLength', 0),
                "content_type": head_response.get('ContentType', 'application/octet-stream'),
                "last_modified": head_response.get('LastModified').isoformat() if 'LastModified' in head_response else None,
                "etag": head_response.get('ETag', '').strip('"'),
                "status": "success",
                "upload_method": "streaming"
            }
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_message = str(e)
            
            if error_code == 'NoSuchBucket':
                logger.error(f"Bucket '{bucket_name}' does not exist")
                raise ValueError(f"Bucket '{bucket_name}' does not exist")
            else:
                logger.error(f"Error streaming file to {s3_uri}: {error_message}")
                raise
        except FileNotFoundError:
            logger.error(f"File not found: {file_path}")
            raise ValueError(f"File not found: {file_path}")
        except Exception as e:
            import traceback
            logger.info('')
            logger.error(f"Unexpected error during streaming upload: {traceback.format_exc()}")
            logger.info('')
            raise
    
    def _upload_file_presigned_put(self, file_path: str, bucket_name: str, object_key: str, content_type: str = None):
        """
        Upload a file using presigned PUT URL.
        This is used as a fallback when regular upload fails with SHA256 mismatch.
        
        Args:
            file_path: Path to the file to upload
            bucket_name: S3 bucket name
            object_key: S3 object key
            content_type: Optional MIME type
        """
        import requests
        
        # Generate presigned PUT URL
        presigned_url = self.s3_client.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': bucket_name,
                'Key': object_key,
                'ContentType': content_type or 'application/octet-stream'
            },
            ExpiresIn=3600
        )
        
        # Stream upload using requests
        with open(file_path, 'rb') as f:
            response = requests.put(
                presigned_url,
                data=f,  # This streams the file
                headers={'Content-Type': content_type or 'application/octet-stream'}
            )
            
            if response.status_code not in [200, 201]:
                raise Exception(f"Presigned PUT upload failed: {response.status_code} - {response.text}")
    
    def _upload_bytes_presigned_post(self, file_content: Union[BinaryIO, bytes], bucket_name: str, object_key: str, content_type: str = None):
        """
        Upload bytes or file-like object using presigned POST.
        This is used as a fallback when regular upload fails with SHA256 mismatch.
        
        Args:
            file_content: Bytes or file-like object to upload
            bucket_name: S3 bucket name
            object_key: S3 object key
            content_type: Optional MIME type
        """
        import requests
        
        # Generate presigned POST data
        post_data = self.s3_client.generate_presigned_post(
            Bucket=bucket_name,
            Key=object_key,
            Fields={
                'Content-Type': content_type or 'application/octet-stream'
            },
            ExpiresIn=300  # 5 minutes
        )
        
        # Prepare file content
        if hasattr(file_content, 'seek'):
            file_content.seek(0)
            content_data = file_content.read()
        else:
            content_data = file_content
        
        # Upload using requests
        files = {
            'file': (
                object_key.split('/')[-1],
                content_data,
                content_type or 'application/octet-stream'
            )
        }
        
        response = requests.post(
            post_data['url'],
            data=post_data['fields'],
            files=files
        )
        
        if response.status_code not in [200, 201, 204]:
            raise Exception(f"Presigned POST upload failed: {response.status_code} - {response.text}")
    
    def upload_file(self, 
                    project_name: str, 
                    file_name: str, 
                    file_content: typing.Union[BinaryIO, bytes],
                    content_type: str = None,
                    prefix: str = None,
                    fetch_presigned_url:bool=False
                    ) -> Dict[str, Any]:
        """
        Upload a file to the project subfolder.
        
        Args:
            project_name: The project name (used as subfolder name)
            file_name: The name of the file to be saved
            file_content: The file content (bytes or file-like object)
            content_type: Optional MIME type
            prefix: Optional additional prefix within the project folder
            fetch_presigned_url: If True, include a presigned URL in the result
            
        Returns:
            Dict with upload status and file metadata
        """
        # Create the S3 URI
        s3_uri = self.create_s3_uri(project_name, file_name, prefix)
        
        # Use the URI-based upload method (this now accepts strings, bytes, or file objects)
        result = self.upload_file_to_uri(s3_uri, file_content, content_type)
        
        # Add a presigned URL if requested
        if fetch_presigned_url:
            result["presigned_url"] = self.get_presigned_url_for_uri(s3_uri)
            
        return result
    
    def upload_file_stream(self,
                          project_name: str,
                          file_name: str,
                          file_path: str,
                          content_type: str = None,
                          prefix: str = None,
                          fetch_presigned_url: bool = False) -> Dict[str, Any]:
        """
        Upload a file from disk using streaming (memory-friendly).
        
        Args:
            project_name: The project name
            file_name: The name of the file to be saved  
            file_path: Path to the file on disk
            content_type: Optional MIME type
            prefix: Optional additional prefix
            fetch_presigned_url: If True, include a presigned URL
            
        Returns:
            Dict with upload status and file metadata
        """
        # Create the S3 URI
        s3_uri = self.create_s3_uri(project_name, file_name, prefix)
        
        # Use the streaming upload method
        result = self.upload_file_stream_to_uri(s3_uri, file_path, content_type)
        
        # Add a presigned URL if requested
        if fetch_presigned_url:
            result["presigned_url"] = self.get_presigned_url_for_uri(s3_uri)
            
        return result
    
    def download_file(self, 
                      project_name: str, 
                      file_name: str,
                      prefix: str = None,
                      local_path: str = None) -> Dict[str, Any]:
        """
        Download a file from the project subfolder.
        
        Args:
            project_name: The project name (used as subfolder name)
            file_name: The name of the file to download
            prefix: Optional additional prefix within the project folder
            local_path: Optional local path to save the file to
            
        Returns:
            Dict with file content and metadata
        """
        # Create the S3 URI
        s3_uri = self.create_s3_uri(project_name, file_name, prefix)
        
        # Use the URI-based method
        return self.download_file_from_uri(s3_uri, local_path)
    
    def parse_s3_uri(self, s3_uri: str) -> Dict[str, str]:
        """
        Parse an S3 URI into bucket name and object key.
        
        Args:
            s3_uri: URI in the format s3://bucket_name/object_key
            
        Returns:
            Dict with 'bucket' and 'key' fields
        """
        if not s3_uri:
            raise ValueError("Empty S3 URI provided")
            
        if not s3_uri.startswith("s3://"):
            raise ValueError(f"Invalid S3 URI format: {s3_uri}, must start with s3://")
            
        # Parse S3 URI to get bucket and key
        parts = s3_uri.split("/")
        if len(parts) < 3:
            raise ValueError(f"Invalid S3 URI format: {s3_uri}, must be s3://bucket_name/object_key")
            
        bucket_name = parts[2]
        if not bucket_name:
            # Use default bucket if not specified
            bucket_name = self.default_bucket
            
        object_key = "/".join(parts[3:])
        if not object_key:
            raise ValueError(f"Invalid S3 URI format: {s3_uri}, object key is empty")
            
        return {
            "bucket": bucket_name,
            "key": object_key
        }
        
    def download_file_from_uri(self, s3_uri: str, local_path: str = None) -> Dict[str, Any]:
        """
        Download a file using an S3 URI directly.
        
        Args:
            s3_uri: URI in the format s3://bucket_name/object_key
            local_path: Optional local path to write the file to
            
        Returns:
            Dict with file content and metadata, or just the file content if local_path is provided
        """
        try:
            # Parse the URI
            parsed = self.parse_s3_uri(s3_uri)
            bucket_name = parsed["bucket"]
            object_key = parsed["key"]
            
            logger.info(f"Downloading file from URI {s3_uri}")
            
            # Get the file from S3
            response = self.s3_client.get_object(
                Bucket=bucket_name,
                Key=object_key
            )
            
            # Read the file content
            content = response['Body'].read()
            
            # If a local path is provided, write the file to it
            if local_path:
                with open(local_path, 'wb') as f:
                    f.write(content)
                logger.info(f"File written to {local_path}")
                return {
                    "uri": s3_uri,
                    "local_path": local_path,
                    "size": response.get('ContentLength', 0),
                    "content_type": response.get('ContentType', 'application/octet-stream'),
                    "last_modified": response.get('LastModified').isoformat() if 'LastModified' in response else None,
                    "etag": response.get('ETag', '').strip('"')
                }
            
            # Otherwise return the content and metadata
            return {
                "uri": s3_uri,
                "content": content,
                "size": response.get('ContentLength', 0),
                "content_type": response.get('ContentType', 'application/octet-stream'),
                "last_modified": response.get('LastModified').isoformat() if 'LastModified' in response else None,
                "etag": response.get('ETag', '').strip('"')
            }
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_message = str(e)
            
            if error_code == 'NoSuchKey':
                logger.error(f"File does not exist at {s3_uri}")
                raise ValueError(f"File does not exist at {s3_uri}")
            elif error_code == 'SignatureDoesNotMatch':
                logger.error(f"S3 signature mismatch during download. Try using 's3v4' signature version.")
                raise ValueError(f"S3 signature mismatch error: {error_message}")
            elif error_code == 'NoSuchBucket':
                logger.error(f"Bucket does not exist in URI: {s3_uri}")
                raise ValueError(f"Bucket does not exist in URI: {s3_uri}")
            else:
                logger.error(f"Error downloading file from URI {s3_uri}: {error_message}")
                raise
            
    def download_file_from_bucket(self, bucket_name: str, object_key: str, local_path: str = None) -> Dict[str, Any]:
        """
        Download a file directly from a specific bucket and key.
        
        Args:
            bucket_name: The name of the S3 bucket
            object_key: The object key in the bucket
            local_path: Optional local path to write the file to
            
        Returns:
            Dict with file content and metadata, or just the file content if local_path is provided
        """
        # Convert to URI and use the URI-based method
        s3_uri = f"s3://{bucket_name}/{object_key}"
        return self.download_file_from_uri(s3_uri, local_path)
    
    def delete_file_by_uri(self, s3_uri: str) -> Dict[str, Any]:
        """
        Delete a file using its S3 URI.
        
        Args:
            s3_uri: The S3 URI of the file to delete
            
        Returns:
            Dict with deletion status
        """
        try:
            # Parse the URI
            parsed = self.parse_s3_uri(s3_uri)
            bucket_name = parsed["bucket"]
            object_key = parsed["key"]
            
            logger.info(f"Deleting file at {s3_uri}")
            
            # Delete the file
            self.s3_client.delete_object(
                Bucket=bucket_name,
                Key=object_key
            )
            
            # Get filename from the object key
            file_name = object_key.split('/')[-1] if '/' in object_key else object_key
            
            return {
                "uri": s3_uri,
                "name": file_name,
                "status": "deleted"
            }
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_message = str(e)
            
            if error_code == 'NoSuchKey':
                # Deletion of non-existent key is often not an error
                logger.warning(f"File does not exist at {s3_uri}, considering as already deleted")
                return {
                    "uri": s3_uri,
                    "name": object_key.split('/')[-1] if '/' in object_key else object_key,
                    "status": "not_found"
                }
            elif error_code == 'SignatureDoesNotMatch':
                logger.error(f"S3 signature mismatch during delete. Try using 's3v4' signature version.")
                raise ValueError(f"S3 signature mismatch error: {error_message}")
            else:
                logger.error(f"Error deleting file at {s3_uri}: {error_message}")
                raise
            
    def delete_file(self, 
                    project_name: str, 
                    file_name: str,
                    prefix: str = None) -> Dict[str, Any]:
        """
        Delete a file from the project subfolder.
        
        Args:
            project_name: The project name (used as subfolder name)
            file_name: The name of the file to delete
            prefix: Optional additional prefix within the project folder
            
        Returns:
            Dict with deletion status
        """
        # Create the S3 URI
        s3_uri = self.create_s3_uri(project_name, file_name, prefix)
        
        # Use the URI-based method
        return self.delete_file_by_uri(s3_uri)
    
    def delete_object(self, bucket_name: str, object_key: str) -> Dict[str, Any]:
        """
        Delete an object from S3 using bucket name and object key.
        
        Args:
            bucket_name: The name of the S3 bucket
            object_key: The object key in the bucket
            
        Returns:
            Dict with deletion status
        """
        try:
            logger.info(f"Deleting object: {bucket_name}/{object_key}")
            
            # Delete the object
            self.s3_client.delete_object(
                Bucket=bucket_name,
                Key=object_key
            )
            
            # Get filename from the object key
            file_name = object_key.split('/')[-1] if '/' in object_key else object_key
            
            return {
                "bucket": bucket_name,
                "key": object_key,
                "name": file_name,
                "status": "deleted"
            }
            
        except ClientError as e:
            logger.error(f"Error deleting object {bucket_name}/{object_key}: {str(e)}")
            raise
            
    def open(self, uri: str, mode: str = "rb", version_id: str = None):
        """
        Open a file-like object for the given S3 URI that's compatible with libraries like PyPDF2.
        
        Args:
            uri: The S3 URI (s3://bucket/key)
            mode: File mode - 'r', 'rb', 'w', 'wb'
            version_id: Optional S3 version ID for reading specific versions
            
        Returns:
            A file-like object for reading or writing
            
        Usage:
            # Reading a file
            with s3.open("s3://bucket/key", "rb") as f:
                data = f.read()
                
            # Writing a file
            with s3.open("s3://bucket/key", "wb") as f:
                f.write(b"Hello, World!")
        """
        if not mode or mode[0] not in ('r', 'w'):
            raise ValueError(f"Invalid mode: {mode}. Must start with 'r' or 'w'")
            
        if mode[0] == "r":
            # Reading mode
            # Get the full content into a BytesIO object to ensure compatibility with libraries like PyPDF2
            body = self.get_streaming_body(uri, version_id=version_id)
            content = body.read()
            
            # Create a standard BytesIO object
            buffer = BytesIO(content)
            
            # Add common attributes that libraries might expect
            buffer.name = uri.split('/')[-1] if '/' in uri else uri
            buffer.mode = mode
            buffer.seek(0)  # Ensure we're at the beginning of the stream
            
            return buffer
        else:
            # Writing mode
            bucket, key = self._split_bucket_and_blob_from_path(uri)
            return FileLikeWritable(self.s3_client, bucket, key)
    
    def get_streaming_body(self, uri: str, version_id: str = None, 
                           before: str = None, after: str = None, at: str = None, **kwargs):
        """
        Get a streaming body for an S3 object.
        
        Args:
            uri: The S3 URI (s3://bucket/key)
            version_id: Optional S3 version ID for reading specific versions
            before: Optional timestamp to get version before this time
            after: Optional timestamp to get version after this time
            at: Optional timestamp to get version at specific time
            **kwargs: Additional arguments for get_object
            
        Returns:
            Streaming body object from S3 client
            
        Raises:
            Exception: If the S3 object cannot be retrieved
        """
        try:
            c = self.s3_client
            bucket, prefix = self._split_bucket_and_blob_from_path(uri)
            
            # Add detailed debugging
            logger.info(f"Getting streaming body for s3://{bucket}/{prefix}")
            
            # Try head_object first to verify the object exists
            try:
                head = c.head_object(Bucket=bucket, Key=prefix)
                logger.info(f"Object exists: size={head.get('ContentLength', 'unknown')}, type={head.get('ContentType', 'unknown')}")
            except Exception as head_err:
                logger.warning(f"Head request failed: {str(head_err)}")
            
            if version_id or before or after or at:
                logger.info(f"Reading versioned object: version_id={version_id}, before={before}, after={after}, at={at}")
                response = self.read_version(
                    uri, version_id=version_id, before=before, after=after, at=at
                )
            else:
                logger.info(f"Getting object: bucket={bucket}, key={prefix}")
                try:
                    response = c.get_object(Bucket=bucket, Key=prefix, **kwargs)
                    logger.info(f"Got object response: {response.get('ContentLength', 'unknown')} bytes")
                    response = response["Body"]
                except Exception as get_err:
                    logger.error(f"Error in get_object: {str(get_err)}")
                    
                    # Try an alternate approach with encoding the key
                    import urllib.parse
                    encoded_key = urllib.parse.quote(prefix)
                    if encoded_key != prefix:
                        logger.info(f"Trying with URL-encoded key: {encoded_key}")
                        try:
                            response = c.get_object(Bucket=bucket, Key=encoded_key, **kwargs)["Body"]
                            logger.info("Success with URL-encoded key")
                        except Exception as encoded_err:
                            logger.error(f"Error with encoded key: {str(encoded_err)}")
                            raise get_err  # Re-raise the original error
                    else:
                        raise
                
            return response
        except Exception as ex:
            logger.error(f"Failed to get streaming body: {str(ex)}")
            raise ex
            
    def _split_bucket_and_blob_from_path(self, uri: str) -> tuple:
        """
        Split S3 URI into bucket and key components.
        
        Args:
            uri: The S3 URI (s3://bucket/key)
            
        Returns:
            Tuple of (bucket, key)
        """
        parsed = self.parse_s3_uri(uri)
        return parsed["bucket"], parsed["key"]
    
    def read_version(self, uri: str, version_id: str = None, 
                    before: str = None, after: str = None, at: str = None) -> Any:
        """
        Read a specific version of an S3 object based on version ID or timestamp.
        
        Args:
            uri: The S3 URI (s3://bucket/key)
            version_id: Optional S3 version ID
            before: Optional timestamp to get version before this time
            after: Optional timestamp to get version after this time
            at: Optional timestamp to get version at specific time
            
        Returns:
            Streaming body from the versioned object
            
        Raises:
            ValueError: If conflicting version parameters are provided
            Exception: If the versioned object cannot be retrieved
        """
        bucket, key = self._split_bucket_and_blob_from_path(uri)
        
        # Check for conflicting parameters
        if sum(x is not None for x in [version_id, before, after, at]) > 1:
            raise ValueError("Only one of version_id, before, after, or at should be specified")
            
        if version_id:
            # Use specific version ID
            return self.s3_client.get_object(
                Bucket=bucket, 
                Key=key,
                VersionId=version_id
            )["Body"]
        elif before or after or at:
            # Get version based on timestamp
            # First, list object versions
            versions = self.s3_client.list_object_versions(
                Bucket=bucket,
                Prefix=key
            ).get('Versions', [])
            
            if not versions:
                raise ValueError(f"No versions found for {uri}")
                
            # Sort versions by LastModified
            versions.sort(key=lambda x: x['LastModified'])
            
            if before:
                # Get the latest version before the specified time
                target_dt = before if isinstance(before, datetime) else datetime.fromisoformat(before)
                valid_versions = [v for v in versions if v['LastModified'] < target_dt]
                if not valid_versions:
                    raise ValueError(f"No versions found before {before}")
                version_id = valid_versions[-1]['VersionId']
            elif after:
                # Get the earliest version after the specified time
                target_dt = after if isinstance(after, datetime) else datetime.fromisoformat(after)
                valid_versions = [v for v in versions if v['LastModified'] > target_dt]
                if not valid_versions:
                    raise ValueError(f"No versions found after {after}")
                version_id = valid_versions[0]['VersionId']
            elif at:
                # Get the version closest to the specified time
                target_dt = at if isinstance(at, datetime) else datetime.fromisoformat(at)
                valid_versions = sorted(versions, 
                                       key=lambda x: abs((x['LastModified'] - target_dt).total_seconds()))
                version_id = valid_versions[0]['VersionId']
            
            # Get the object with the determined version ID
            return self.s3_client.get_object(
                Bucket=bucket, 
                Key=key,
                VersionId=version_id
            )["Body"]
        else:
            # This should never be reached due to the logic at the start of the function
            raise ValueError("No version parameters specified")
            
    def get_presigned_url_for_uri(self,
                                  s3_uri: str,
                                  operation: str = 'get_object',
                                  expires_in: int = 3600) -> str:
        """
        Generate a presigned URL for a specific S3 URI.
        
        Args:
            s3_uri: The S3 URI (s3://bucket_name/object_key)
            operation: The S3 operation ('get_object', 'put_object', etc.)
            expires_in: URL expiration time in seconds
            
        Returns:
            Presigned URL string
        """
        try:
            # Parse the URI
            parsed = self.parse_s3_uri(s3_uri)
            bucket_name = parsed["bucket"]
            object_key = parsed["key"]
            
            logger.debug(f"Generating presigned URL for {s3_uri}")
            
            # Generate the URL
            url = self.s3_client.generate_presigned_url(
                ClientMethod=operation,
                Params={
                    'Bucket': bucket_name,
                    'Key': object_key
                },
                ExpiresIn=expires_in
            )
            
            return url
            
        except ClientError as e:
            logger.error(f"Error generating presigned URL for {s3_uri}: {str(e)}")
            raise
            
    def get_presigned_url(self,
                          project_name: str,
                          file_name: str,
                          operation: str = 'get_object',
                          expires_in: int = 3600,
                          prefix: str = None) -> str:
        """
        Generate a presigned URL for a specific operation on a file.
        
        Args:
            project_name: The project name (used as subfolder name)
            file_name: The name of the file
            operation: The S3 operation ('get_object', 'put_object', etc.)
            expires_in: URL expiration time in seconds
            prefix: Optional additional prefix within the project folder
            
        Returns:
            Presigned URL string
        """
        # Create the S3 URI
        s3_uri = self.create_s3_uri(project_name, file_name, prefix)
        
        # Use the URI-based method
        return self.get_presigned_url_for_uri(s3_uri, operation, expires_in)
    
    async def upload_file_multipart(self,
                                    project_name: str,
                                    file_name: str,
                                    file_path: str,
                                    content_type: str = None,
                                    prefix: str = None,
                                    chunk_size: int = 10 * 1024 * 1024) -> Dict[str, Any]:
        """
        Upload a large file using multipart upload for memory-efficient streaming.
        
        Args:
            project_name: The project name
            file_name: The file name
            file_path: Path to the file on disk
            content_type: Optional MIME type
            prefix: Optional additional prefix
            chunk_size: Size of each chunk in bytes (default 10MB)
            
        Returns:
            Dict with upload status and metadata
        """
        import asyncio
        from concurrent.futures import ThreadPoolExecutor
        
        try:
            # Create the S3 key
            full_prefix = f"{project_name}/"
            if prefix:
                prefix = prefix.strip('/')
                if prefix:
                    full_prefix += f"{prefix}/"
            
            s3_key = full_prefix + file_name
            
            # Get file size
            file_size = os.path.getsize(file_path)
            
            # For small files, use regular upload
            if file_size < chunk_size:
                with open(file_path, 'rb') as f:
                    return self.upload_file(
                        project_name=project_name,
                        file_name=file_name,
                        file_content=f,
                        content_type=content_type,
                        prefix=prefix
                    )
            
            # Start multipart upload
            logger.info(f"Starting multipart upload for large file: {file_name} ({file_size} bytes)")
            
            create_params = {
                'Bucket': self.default_bucket,
                'Key': s3_key
            }
            if content_type:
                create_params['ContentType'] = content_type
            
            response = self.s3_client.create_multipart_upload(**create_params)
            upload_id = response['UploadId']
            
            # Upload parts
            parts = []
            part_number = 1
            
            def upload_part(part_data: bytes, part_num: int) -> dict:
                """Upload a single part"""
                response = self.s3_client.upload_part(
                    Bucket=self.default_bucket,
                    Key=s3_key,
                    PartNumber=part_num,
                    UploadId=upload_id,
                    Body=part_data
                )
                return {
                    'PartNumber': part_num,
                    'ETag': response['ETag']
                }
            
            # Use thread pool for parallel uploads
            with ThreadPoolExecutor(max_workers=5) as executor:
                futures = []
                
                with open(file_path, 'rb') as f:
                    while True:
                        # Read chunk
                        chunk = f.read(chunk_size)
                        if not chunk:
                            break
                        
                        # Submit upload task
                        future = executor.submit(upload_part, chunk, part_number)
                        futures.append(future)
                        part_number += 1
                
                # Wait for all uploads to complete
                for future in futures:
                    part = future.result()
                    parts.append(part)
            
            # Complete multipart upload
            complete_response = self.s3_client.complete_multipart_upload(
                Bucket=self.default_bucket,
                Key=s3_key,
                UploadId=upload_id,
                MultipartUpload={'Parts': parts}
            )
            
            # Create S3 URI
            s3_uri = f"s3://{self.default_bucket}/{s3_key}"
            
            logger.info(f"Multipart upload completed: {s3_uri}")
            
            return {
                "uri": s3_uri,
                "name": file_name,
                "size": file_size,
                "content_type": content_type or "application/octet-stream",
                "status": "success",
                "upload_type": "multipart",
                "parts": len(parts)
            }
            
        except Exception as e:
            # Abort multipart upload on error
            if 'upload_id' in locals():
                try:
                    self.s3_client.abort_multipart_upload(
                        Bucket=self.default_bucket,
                        Key=s3_key,
                        UploadId=upload_id
                    )
                except:
                    pass
            
            logger.error(f"Error in multipart upload: {str(e)}")
            raise
    
    def upload_file_multipart_sync(self,
                                   project_name: str,
                                   file_name: str,
                                   file_path: str,
                                   content_type: str = None,
                                   prefix: str = None,
                                   chunk_size: int = 10 * 1024 * 1024) -> Dict[str, Any]:
        """
        Synchronous version of multipart upload for use in async contexts.
        """
        import asyncio
        
        # Create a new event loop for this sync method
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(
                self.upload_file_multipart(
                    project_name=project_name,
                    file_name=file_name,
                    file_path=file_path,
                    content_type=content_type,
                    prefix=prefix,
                    chunk_size=chunk_size
                )
            )
        finally:
            loop.close()
    
    def upload_file_from_path(self,
                              project_name: str,
                              file_name: str,
                              file_path: str,
                              content_type: str = None,
                              prefix: str = None) -> Dict[str, Any]:
        """
        Upload a file from a file path, choosing the best method based on file size.
        This method handles the SHA mismatch issue properly.
        """
        file_size = os.path.getsize(file_path)
        
        if file_size > 10 * 1024 * 1024:  # > 10MB
            # Use multipart upload for large files
            logger.info(f"Using multipart upload for {file_name} ({file_size} bytes)")
            return self.upload_file_multipart_sync(
                project_name=project_name,
                file_name=file_name,
                file_path=file_path,
                content_type=content_type,
                prefix=prefix
            )
        else:
            # For small files, use regular upload with proper handling
            logger.info(f"Using regular upload for {file_name} ({file_size} bytes)")
            
            # Read the file content completely to avoid SHA mismatch
            with open(file_path, 'rb') as f:
                file_content = f.read()
            
            return self.upload_file(
                project_name=project_name,
                file_name=file_name,
                file_content=file_content,
                content_type=content_type,
                prefix=prefix
            )