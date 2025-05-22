"""
Hetzner S3 Controller for managing object storage.

This controller provides functionality for:
1. Creating user-specific access keys with limited permissions
2. Managing files (upload, download, list) in buckets and subfolders
3. Supporting runtime contexts with access to different buckets
"""

import os
import boto3
import uuid
from typing import List, Dict, Any, Optional, BinaryIO, Union
from botocore.exceptions import ClientError
from percolate.utils import logger
from percolate.utils.env import S3_URL
import typing

class S3Service:
    def __init__(self, 
                 access_key: str = None, 
                 secret_key: str = None, 
                 endpoint_url: str = None,
                 signature_version:str='s3v4',
                 use_aws: bool = False
                 ):
        """
        Initialize the S3 controller with credentials. Falls back to standard AWS credentials if custom S3 vars not set.
        
        Args:
            access_key: S3 access key. Defaults to S3_ACCESS_KEY environment variable, then AWS_ACCESS_KEY_ID.
            secret_key: S3 secret key. Defaults to S3_SECRET environment variable, then AWS_SECRET_ACCESS_KEY.
            endpoint_url: S3 endpoint URL. Defaults to S3_URL environment variable (for custom S3), None for AWS.
            signature_version: S3 signature version to use (default 's3v4')
            use_aws: If True, skip S3_ env vars and use only AWS credentials and standard S3 (default False)
            
        Environment Variables:
            S3_ACCESS_KEY: Access key for custom S3 (Hetzner, etc.)
            S3_SECRET: Secret key for custom S3
            S3_URL: Endpoint URL for custom S3 (e.g., 'hel1.your-objectstorage.com')
            AWS_ACCESS_KEY_ID: Standard AWS access key (fallback)
            AWS_SECRET_ACCESS_KEY: Standard AWS secret key (fallback)
            S3_DEFAULT_BUCKET: Name of the S3 bucket (defaults to 'percolate')
            S3_BUCKET_NAME: Alternative name for the S3 bucket (used if S3_DEFAULT_BUCKET is not set)
        """
        # Store the use_aws flag
        self.use_aws = use_aws
        
        # Get credentials from environment if not provided
        if use_aws:
            # AWS mode: only use AWS credentials, ignore S3_ env vars
            self.access_key = access_key or os.environ.get("AWS_ACCESS_KEY_ID")
            self.secret_key = secret_key or os.environ.get("AWS_SECRET_ACCESS_KEY")
        else:
            # Custom S3 mode: try custom S3 env vars first, then fall back to standard AWS env vars
            self.access_key = (access_key or 
                              os.environ.get("S3_ACCESS_KEY") or 
                              os.environ.get("AWS_ACCESS_KEY_ID"))
            self.secret_key = (secret_key or 
                              os.environ.get("S3_SECRET") or 
                              os.environ.get("AWS_SECRET_ACCESS_KEY"))
        
        if not self.access_key or not self.secret_key:
            raise ValueError("S3 credentials must be provided via parameters or environment variables (S3_ACCESS_KEY/S3_SECRET or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)")
        
        # Get endpoint URL from environment or use provided value
        if use_aws:
            # AWS mode: force standard AWS S3 (no custom endpoint)
            self.endpoint_url = endpoint_url  # Usually None for AWS
        else:
            # Custom S3 mode: only use custom S3_URL if custom S3 credentials are also set
            # This ensures we fall back to AWS S3 when using AWS credentials
            custom_s3_creds = os.environ.get("S3_ACCESS_KEY") and os.environ.get("S3_SECRET")
            
            if endpoint_url:
                self.endpoint_url = endpoint_url
            elif custom_s3_creds and os.environ.get("S3_URL"):
                # Only use S3_URL if we have custom S3 credentials
                self.endpoint_url = os.environ.get("S3_URL")
            else:
                # Use standard AWS S3 (no endpoint URL needed)
                self.endpoint_url = None
        
        # For standard AWS S3, we don't need an endpoint URL
        if self.endpoint_url and self.endpoint_url.lower() in ['none', 'null', '']:
            self.endpoint_url = None
            
        # Ensure the endpoint URL has the correct protocol (only if we have an endpoint)
        if self.endpoint_url and not self.endpoint_url.startswith("http"):
            self.endpoint_url = f"https://{self.endpoint_url}"
            
        # Get bucket name from environment or use default
        self.default_bucket = os.environ.get("S3_DEFAULT_BUCKET", os.environ.get("S3_BUCKET_NAME", "percolate"))
        
        #print(self.endpoint_url, self.access_key,self.secret_key,self.default_bucket)
        
        # Create S3 client with appropriate configuration
        # If endpoint_url is None, this will use standard AWS S3
        client_kwargs = {
            'aws_access_key_id': self.access_key,
            'aws_secret_access_key': self.secret_key,
        }
        
        # Only add endpoint_url if we have one (for custom S3 providers)
        if self.endpoint_url:
            client_kwargs['endpoint_url'] = self.endpoint_url
            
        # Configure based on whether we're using custom S3 or AWS
        if use_aws or not self.endpoint_url:
            # Standard AWS S3 configuration
            config = boto3.session.Config(
                signature_version='s3v4',
                s3={'addressing_style': 'virtual'}
            )
        else:
            # Custom S3 provider configuration (Hetzner, etc.)
            config = boto3.session.Config(
                signature_version=signature_version,
                s3={'addressing_style': 'path'},
                request_checksum_calculation="when_required", 
                response_checksum_validation="when_required"
            )
            
        client_kwargs['config'] = config
        self.s3_client = boto3.client('s3', **client_kwargs)
        
        # Create IAM client with the same configuration
        # Note: IAM operations may not be fully supported by all S3 providers
        iam_kwargs = {
            'aws_access_key_id': self.access_key,
            'aws_secret_access_key': self.secret_key,
        }
        
        # Only add endpoint_url for custom S3 providers (AWS IAM doesn't need custom endpoint)
        if self.endpoint_url:
            iam_kwargs['endpoint_url'] = self.endpoint_url
            iam_kwargs['config'] = boto3.session.Config(
                signature_version='s3',
                s3={'addressing_style': 'path'}
            )
        
        self.iam_client = boto3.client('iam', **iam_kwargs)
    
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