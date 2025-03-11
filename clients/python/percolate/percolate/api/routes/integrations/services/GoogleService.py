from percolate.api.routes.integrations.services import EmailMessage
import json
import time
import httpx
from pathlib import Path
from datetime import datetime,timedelta
import html2text
import base64
import os

TOKEN_PATH = Path.home() / '.percolate' / 'auth' / 'token'
SCOPES = ['https://www.googleapis.com/auth/gmail.readonly']

async def refresh_token(refresh_token: str) -> dict:
    """Refresh the access token using the refresh token."""
    token_url = "https://oauth2.googleapis.com/token"
    client_id = os.environ.get('GOOGLE_CLIENT_ID')
    client_secret =os.environ.get('GOOGLE_CLIENT_SECRET')
    assert client_id and client_id, "The google service id/secret are not set"
    
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

            # Save the new token
            with open(TOKEN_PATH, "w") as f:
                json.dump(new_token, f)
            return new_token
        else:
            raise Exception(f"Failed to refresh token: {response.text}")

async def check_token():
    """check the token exists and has not expired"""
    if TOKEN_PATH.exists():
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
            raise Exception('expired token')
    return token

        
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

class GmailService:
    def __init__(self, token=None):
        
        """for convenience if the token is null we use convention to try and read it from percolate home"""
        self.token = token


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
            
        self.token = await check_token()
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
            async with httpx.AsyncClient() as client:
                response = await client.get(url, headers=headers, params=params)

                if response.status_code != 200:
                    raise Exception(f"Error fetching emails: {response.text}")

                messages = response.json().get("messages", [])

                email_data = []
                for message in messages:
                    msg_url = f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{message['id']}"
                    msg_response = await client.get(msg_url, headers=headers)

                    if msg_response.status_code != 200:
                        #print(f"Error fetching message {message['id']}: {msg_response.text}")
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
                    
                    #print(email_info['from'])

                    #client filter - not sure if their is a server filter that does what we want
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
        
if __name__=="__main__":
    import asyncio
    
    gs = GmailService()
    data = asyncio.run(gs.fetch_latest_emails(limit = 5, since_ts="2025-03-01", filter_domain='substack.com'))
    print(data)