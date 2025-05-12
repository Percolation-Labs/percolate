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
from typing import List, Dict, Any, Optional, BinaryIO
from botocore.exceptions import ClientError
from percolate.utils import logger
from percolate.utils.env import S3_URL
import typing

class S3Service:
    def __init__(self, 
                 access_key: str = None, 
                 secret_key: str = None, 
                 endpoint_url: str = None,
                 signature_version:str='s3v4'
                 ):
        """
        Initialize the S3 controller with Hetzner S3 credentials.
        
        Args:
            access_key: S3 access key. Defaults to S3_ACCESS_KEY environment variable.
            secret_key: S3 secret key. Defaults to S3_SECRET environment variable.
            endpoint_url: S3 endpoint URL. Defaults to S3_URL environment variable.
            
        Environment Variables:
            S3_ACCESS_KEY: Access key for Hetzner S3
            S3_SECRET: Secret key for Hetzner S3
            S3_URL: Endpoint URL for Hetzner S3 (e.g., 'hel1.your-objectstorage.com')
            S3_DEFAULT_BUCKET: Name of the S3 bucket (defaults to 'percolate')
            S3_BUCKET_NAME: Alternative name for the S3 bucket (used if S3_DEFAULT_BUCKET is not set)
        """
        # Get credentials from environment if not provided
        self.access_key = access_key or os.environ.get("S3_ACCESS_KEY")
        self.secret_key = secret_key or os.environ.get("S3_SECRET")
        
        if not self.access_key or not self.secret_key:
            raise ValueError("S3 credentials must be provided via parameters or environment variables")
        
        # Get endpoint URL from environment or use provided value
        self.endpoint_url = endpoint_url or os.environ.get("S3_URL",S3_URL)
        if not self.endpoint_url:
            raise ValueError("S3_URL environment variable is required")
            
        # Ensure the endpoint URL has the correct protocol
        if not self.endpoint_url.startswith("http"):
            self.endpoint_url = f"https://{self.endpoint_url}"
            
        # Get bucket name from environment or use default
        self.default_bucket = os.environ.get("S3_DEFAULT_BUCKET", os.environ.get("S3_BUCKET_NAME", "percolate"))
        
        #print(self.endpoint_url, self.access_key,self.secret_key,self.default_bucket)
        
        # Create S3 clients with appropriate configuration for Hetzner
        self.s3_client = boto3.client(
            's3',
            aws_access_key_id=self.access_key,
            aws_secret_access_key=self.secret_key,
            endpoint_url=self.endpoint_url,
            # Use S3 signature (not s3v4) for compatibility with Hetzner
            # This configuration has been tested to work with file uploads
            config=boto3.session.Config(
                signature_version=signature_version,
                s3={'addressing_style': 'path'}
            )
        )
        
        # Create IAM client with the same configuration
        # Note: IAM operations may not be fully supported by all S3 providers
        self.iam_client = boto3.client(
            'iam',
            aws_access_key_id=self.access_key,
            aws_secret_access_key=self.secret_key,
            endpoint_url=self.endpoint_url,
            config=boto3.session.Config(
                signature_version='s3',
                s3={'addressing_style': 'path'}
            )
        )
    
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
            logger.error(f"Error listing files: {str(e)}")
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
        
    def upload_file_to_uri(self, 
                         s3_uri: str,
                         file_content: typing.Union[BinaryIO, bytes],
                         content_type: str = None
                         ) -> Dict[str, Any]:
        """
        Upload a file to a specific S3 URI.
        
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
            put_params = {
                'Bucket': bucket_name,
                'Key': object_key,
                'Body': file_content
            }
            
            # Add content type if provided
            if content_type:
                put_params['ContentType'] = content_type
                
            logger.debug(f"Uploading file to {s3_uri}")
            # Upload the file using put_object
            response = self.s3_client.put_object(**put_params)
            
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
            logger.error(f"Error uploading file to {s3_uri}: {str(e)}")
            raise
    
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
        
        # Use the URI-based upload method
        result = self.upload_file_to_uri(s3_uri, file_content, content_type)
        
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
            logger.error(f"Error downloading file from URI {s3_uri}: {str(e)}")
            if e.response['Error']['Code'] == 'NoSuchKey':
                raise ValueError(f"File does not exist at {s3_uri}")
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
            logger.error(f"Error deleting file at {s3_uri}: {str(e)}")
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