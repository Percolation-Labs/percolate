from percolate.api.routes.integrations.services import EmailMessage
import json
import time
import httpx
from pathlib import Path
from datetime import datetime, timedelta
import html2text
import base64
import os
from typing import Dict, List, Optional, Any, Union

TOKEN_PATH = Path.home() / '.percolate' / 'auth' / 'token'
SCOPES = [
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/drive.readonly',
    'https://www.googleapis.com/auth/documents.readonly'
]

async def refresh_token(refresh_token: str) -> dict:
    """Refresh the access token using the refresh token."""
    token_url = "https://oauth2.googleapis.com/token"
    client_id = os.environ.get('GOOGLE_CLIENT_ID')
    client_secret = os.environ.get('GOOGLE_CLIENT_SECRET')
    assert client_id and client_secret, "The google service id/secret are not set"
    
    async with httpx.AsyncClient() as client:
        response = await client.post(
            token_url,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
        if response.status_code == 200:
            new_token = response.json()
            new_token["expires_at"] = int(time.time()) + new_token["expires_in"]
            new_token["refresh_token"] = refresh_token  # Keep the refresh token

            # Save the new token
            with open(TOKEN_PATH, "w") as f:
                json.dump(new_token, f)
            return new_token
        else:
            raise Exception(f"Failed to refresh token: {response.text}")

async def check_token(token_data=None):
    """Check the token exists and has not expired"""
    if token_data:
        token = token_data
    elif TOKEN_PATH.exists():
        with open(TOKEN_PATH, "r") as f:
            token = json.load(f)
    else:
        raise Exception('not auth')
    
    current_time = int(time.time())
    if current_time >= token.get("expires_at", 0):
        if "refresh_token" in token:
            try:
                token = await refresh_token(token["refresh_token"])
            except Exception as e:
                raise
        else:
            raise Exception('expired token and no refresh token available')
    return token


class GoogleServiceBase:
    """Base class for Google Service implementations with token handling."""
    
    def __init__(self, token=None):
        """
        Initialize with an optional token.
        If token is None, we'll try to read it from the conventional location.
        """
        self.token = token
        
    async def ensure_valid_token(self):
        """Ensure we have a valid token, refreshing if necessary."""
        self.token = await check_token(self.token)
        return self.token

    @classmethod
    async def from_user_id(cls, user_id: str):
        """
        Create a service instance using tokens stored in the database for a user.
        
        Args:
            user_id: The user ID to look up credentials for
        
        Returns:
            An initialized instance of the service
        """
        import percolate as p8
        from percolate.models.sync import SyncCredential
        
        # Query the database for credentials
        repo = p8.repository(SyncCredential)
        creds = repo.select(userid=user_id, provider="google_drive")
        
        if not creds:
            raise Exception(f"No Google credentials found for user {user_id}")
            
        # Use the first valid credential
        cred_data = creds[0]
        
        # Convert to model if it's a dictionary
        if isinstance(cred_data, dict):
            cred = SyncCredential.model_parse(cred_data)
        else:
            cred = cred_data
            
        # Create token dictionary in expected format
        token_data = {
            "access_token": cred.access_token,
            "refresh_token": cred.refresh_token,
            "expires_at": int(cred.token_expiry.timestamp()) if cred.token_expiry else 0
        }
        
        # Create and return the service
        service = cls(token=token_data)
        await service.ensure_valid_token()  # This will refresh if needed
        
        # Update the database with refreshed token if it changed
        if token_data["access_token"] != service.token["access_token"]:
            cred.access_token = service.token["access_token"]
            cred.token_expiry = datetime.fromtimestamp(service.token["expires_at"])
            repo.update_records(cred)
            
        return service


class GmailService(GoogleServiceBase):
    async def fetch_latest_emails(self, limit: int = 5, fetch_limit: int = 100, domain_filter: str = None, since_ts: int = None, since_iso_date:str=None, unread_only:bool=False, **kwargs):
        """Fetch latest emails from Gmail.
        
        Args:
            limit: how many emails to fetch after filtering  (client limit)
            fetch_limit: how many emails to fetch before filtering - this is a batching hint and not a fetch size
            filter_domain sender -e.g. we often fetch emails such as substack emails
            since_ts: unix timestamp since date
        """
        
        if since_iso_date and not since_ts:
            since_ts = int(datetime.fromisoformat(since_iso_date).timestamp())        
            
        self.token = await self.ensure_valid_token()
        headers = {
            "Authorization": f"Bearer {self.token['access_token']}",
        }
        params = { "labelIds": "INBOX", "q":'', "maxResults": fetch_limit, 'orderBy': 'date' }
        if unread_only:
            params["q"] += "is:unread",
        if since_ts:
            params["q"] += f" after:{since_ts}"  

        url = "https://gmail.googleapis.com/gmail/v1/users/me/messages"

        try:
            # Use reasonable timeout for API requests
            timeout = httpx.Timeout(connect=30.0, read=60.0, write=60.0, pool=30.0)
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.get(url, headers=headers, params=params)

                if response.status_code != 200:
                    raise Exception(f"Error fetching emails: {response.text}")

                messages = response.json().get("messages", [])

                email_data = []
                for message in messages:
                    msg_url = f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{message['id']}"
                    msg_response = await client.get(msg_url, headers=headers)

                    if msg_response.status_code != 200:
                        continue

                    msg = msg_response.json()
                    
                    email_info = {
                        "snippet": msg["snippet"],
                        "id": msg["id"],
                        "from": next(header["value"] for header in msg["payload"]["headers"] if header["name"] == "From"),
                        "subject": next(header["value"] for header in msg["payload"]["headers"] if header["name"] == "Subject"),
                        "date": extract_email_date(msg["payload"]["headers"]),
                        "content": extract_email_body(msg["payload"]),
                    }

                    # Client filter - not sure if there is a server filter that does what we want
                    if domain_filter:
                        if domain_filter in email_info["from"]:
                            email_data.append(email_info)
                    else:
                        email_data.append(email_info)
                    
                    if len(email_data) == limit:
                        break

            return email_data

        except Exception as e:
            raise


class DriveService(GoogleServiceBase):
    """Service for interacting with Google Drive API."""
    
    # API Endpoints
    GOOGLE_DRIVE_API = "https://www.googleapis.com/drive/v3"
    GOOGLE_DOCS_API = "https://docs.googleapis.com/v1"
    
    async def test_token(self):
        """Test the access token with basic user info requests."""
        self.token = await self.ensure_valid_token()
        headers = {"Authorization": f"Bearer {self.token['access_token']}"}
        
        # Use reasonable timeout for API requests
        timeout = httpx.Timeout(connect=30.0, read=60.0, write=60.0, pool=30.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            # Test user info
            user_response = await client.get(
                "https://www.googleapis.com/oauth2/v2/userinfo", 
                headers=headers
            )
            
            # Test drive info
            drive_response = await client.get(
                f"{self.GOOGLE_DRIVE_API}/about?fields=user", 
                headers=headers
            )
            
            return {
                "user_info": user_response.json() if user_response.status_code == 200 else None,
                "drive_info": drive_response.json() if drive_response.status_code == 200 else None,
                "status": "success" if user_response.status_code == 200 and drive_response.status_code == 200 else "error"
            }
    
    async def list_files(self, folder_id='root', recursive=True, file_fields=None, include_trashed=False):
        """
        List files in a specific folder with pagination support.
        
        Args:
            folder_id: ID of the folder to list files from (default is 'root')
            recursive: Whether to list files in subfolders recursively
            file_fields: Fields to include in the response (default is id, name, mimeType, parents)
            include_trashed: Whether to include trashed files
            
        Returns:
            List of file objects
        """
        self.token = await self.ensure_valid_token()
        headers = {"Authorization": f"Bearer {self.token['access_token']}"}
        
        if not file_fields:
            file_fields = "id, name, mimeType, parents, createdTime, modifiedTime, size, md5Checksum, webViewLink"
            
        # Query to find all files in the specified folder
        query = f"'{folder_id}' in parents" 
        if not include_trashed:
            query += " and trashed = false"
            
        all_files = []
        
        # Use reasonable timeout for API requests
        timeout = httpx.Timeout(connect=30.0, read=60.0, write=60.0, pool=30.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            # First get this folder's files
            page_token = None
            while True:
                params = {
                    "q": query,
                    "fields": f"nextPageToken, files({file_fields})",
                    "pageSize": 100
                }
                
                if page_token:
                    params["pageToken"] = page_token
                    
                response = await client.get(
                    f"{self.GOOGLE_DRIVE_API}/files", 
                    headers=headers, 
                    params=params
                )
                
                if response.status_code != 200:
                    raise Exception(f"Error listing files: {response.text}")
                    
                result = response.json()
                files = result.get("files", [])
                all_files.extend(files)
                
                page_token = result.get("nextPageToken")
                if not page_token:
                    break
            
            # If recursive, process subfolders
            if recursive:
                subfolders = [f for f in all_files if f.get("mimeType") == "application/vnd.google-apps.folder"]
                for subfolder in subfolders:
                    subfolder_files = await self.list_files(
                        folder_id=subfolder.get("id"), 
                        recursive=True,
                        file_fields=file_fields,
                        include_trashed=include_trashed
                    )
                    all_files.extend(subfolder_files)
                
        return all_files
    
    async def list_shared_drives(self):
        """List all shared drives the user has access to."""
        self.token = await self.ensure_valid_token()
        headers = {"Authorization": f"Bearer {self.token['access_token']}"}
        
        all_drives = []
        
        # Use reasonable timeout for API requests
        timeout = httpx.Timeout(connect=30.0, read=60.0, write=60.0, pool=30.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            page_token = None
            while True:
                params = {
                    "fields": "nextPageToken, drives(id, name)",
                    "pageSize": 100
                }
                
                if page_token:
                    params["pageToken"] = page_token
                    
                response = await client.get(
                    f"{self.GOOGLE_DRIVE_API}/drives", 
                    headers=headers, 
                    params=params
                )
                
                if response.status_code != 200:
                    raise Exception(f"Error listing shared drives: {response.text}")
                    
                result = response.json()
                drives = result.get("drives", [])
                all_drives.extend(drives)
                
                page_token = result.get("nextPageToken")
                if not page_token:
                    break
                    
        return all_drives
    
    async def get_file_content(self, file_id, export_format=None):
        """
        Get the content of a file, with optional format conversion for Google Docs.
        
        Args:
            file_id: The ID of the file to download
            export_format: Optional format to export Google Docs (e.g., 'application/pdf')
            
        Returns:
            File content as bytes and content type
        """
        self.token = await self.ensure_valid_token()
        headers = {"Authorization": f"Bearer {self.token['access_token']}"}
        
        # Use longer timeout for file downloads (10 minutes for large files)
        timeout = httpx.Timeout(
            connect=30.0,      # 30 seconds to establish connection
            read=600.0,        # 10 minutes to read the response
            write=600.0,       # 10 minutes to write (for uploads)
            pool=30.0          # 30 seconds to acquire connection from pool
        )
        
        async with httpx.AsyncClient(timeout=timeout) as client:
            # First get file metadata to determine type
            response = await client.get(
                f"{self.GOOGLE_DRIVE_API}/files/{file_id}?fields=mimeType,name", 
                headers=headers
            )
            
            if response.status_code != 200:
                raise Exception(f"Error getting file metadata: {response.text}")
                
            file_info = response.json()
            mime_type = file_info.get("mimeType")
            
            # Handle Google Docs
            if mime_type.startswith("application/vnd.google-apps"):
                if mime_type == "application/vnd.google-apps.document":
                    # Get Google Doc content
                    if export_format:
                        # Export to requested format
                        response = await client.get(
                            f"{self.GOOGLE_DRIVE_API}/files/{file_id}/export",
                            headers=headers,
                            params={"mimeType": export_format}
                        )
                    else:
                        # Get document structure
                        response = await client.get(
                            f"{self.GOOGLE_DOCS_API}/documents/{file_id}",
                            headers=headers
                        )
            else:
                # Regular file download
                response = await client.get(
                    f"{self.GOOGLE_DRIVE_API}/files/{file_id}?alt=media",
                    headers=headers
                )
            
            if response.status_code != 200:
                raise Exception(f"Error downloading file content: {response.text}")
                
            return response.content, response.headers.get("content-type", mime_type)


# Helper functions 
def extract_email_body(payload):
    """Extracts the email body from the payload, handling different formats."""
    if "parts" in payload:  # Multipart email
        for part in payload["parts"]:
            mime_type = part.get("mimeType", "")
            if mime_type == "text/plain":  # Prefer plain text if available
                return base64.urlsafe_b64decode(part["body"]["data"]).decode("utf-8")
            if mime_type == "text/html":  # Convert HTML to Markdown
                html_content = base64.urlsafe_b64decode(part["body"]["data"]).decode("utf-8")
                return html2text.html2text(html_content)
    elif "body" in payload and "data" in payload["body"]:  # Single-part email
        mime_type = payload.get("mimeType", "")
        content = base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8")
        return html2text.html2text(content) if mime_type == "text/html" else content
    return "[No content]"

def extract_email_date(headers):
    """Extracts the email date from headers and converts it to a readable format."""
    for header in headers:
        if header["name"] == "Date":
            try:
                email_date = datetime.strptime(header["value"], "%a, %d %b %Y %H:%M:%S %z")
                return email_date.strftime("%Y-%m-%d %H:%M:%S %Z")
            except ValueError:
                pass  # In case the date format varies
    return "[Unknown Date]"