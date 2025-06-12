"""
Simple Google OAuth implementation without Authlib dependencies.
This module handles the Google OAuth flow using standard libraries.
"""

import os
import json
import uuid
import httpx
import logging
from typing import Dict, Optional, Any
from urllib.parse import urlencode
from datetime import datetime, timezone, timedelta

# Google OAuth endpoints
GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo"

# Logger for OAuth operations
logger = logging.getLogger("google_oauth")

class GoogleOAuth:
    """Simple Google OAuth client without Authlib."""
    
    def __init__(self, client_id: str, client_secret: str, scopes: list):
        """Initialize the Google OAuth client.
        
        Args:
            client_id: Google OAuth client ID
            client_secret: Google OAuth client secret
            scopes: List of OAuth scopes to request
        """
        self.client_id = client_id
        self.client_secret = client_secret
        self.scopes = scopes
    
    def get_authorization_url(self, redirect_uri: str, state: Optional[str] = None) -> str:
        """Generate the Google authorization URL.
        
        Args:
            redirect_uri: OAuth callback URL
            state: Optional state parameter for CSRF protection
            
        Returns:
            The full authorization URL to redirect the user to
        """
        if not state:
            state = str(uuid.uuid4())
            
        params = {
            "client_id": self.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": " ".join(self.scopes),
            "state": state,
            "prompt": "consent",
            "access_type": "offline",
            "include_granted_scopes": "true"
        }
        
        return f"{GOOGLE_AUTH_URL}?{urlencode(params)}"
    
    async def exchange_code_for_token(self, code: str, redirect_uri: str) -> Dict[str, Any]:
        """Exchange authorization code for access token.
        
        Args:
            code: Authorization code from Google
            redirect_uri: OAuth callback URL
            
        Returns:
            Dictionary containing token response (access_token, refresh_token, etc.)
        """
        payload = {
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirect_uri
        }
        
        async with httpx.AsyncClient() as client:
            response = await client.post(GOOGLE_TOKEN_URL, data=payload)
            
            if response.status_code != 200:
                logger.error(f"Token exchange failed: {response.text}")
                raise ValueError(f"Failed to exchange code for token: {response.text}")
                
            return response.json()
    
    async def get_user_info(self, access_token: str) -> Dict[str, Any]:
        """Get user info using the access token.
        
        Args:
            access_token: OAuth access token
            
        Returns:
            Dictionary containing user information
        """
        headers = {"Authorization": f"Bearer {access_token}"}
        
        async with httpx.AsyncClient() as client:
            response = await client.get(GOOGLE_USERINFO_URL, headers=headers)
            
            if response.status_code != 200:
                logger.error(f"Failed to get user info: {response.text}")
                raise ValueError(f"Failed to get user info: {response.text}")
                
            return response.json()
    
    def verify_state(self, original_state: str, returned_state: str) -> bool:
        """Verify the state parameter to protect against CSRF attacks.
        
        Args:
            original_state: The state sent in the authorization request
            returned_state: The state returned by Google
            
        Returns:
            True if states match, False otherwise
        """
        return original_state == returned_state


# Helper functions for token/user management

def extract_user_info(token_response: Dict[str, Any], user_info: Dict[str, Any]) -> Dict[str, Any]:
    """Extract and format user information from token response and user info.
    
    Args:
        token_response: Dictionary containing OAuth token data
        user_info: Dictionary containing user profile data
        
    Returns:
        Combined user and token information
    """
    # Calculate token expiry
    expires_in = token_response.get('expires_in', 3600)  # Default 1 hour
    token_expiry = datetime.now(timezone.utc) + timedelta(seconds=expires_in)
    
    # Extract user information
    email = user_info.get('email')
    name = user_info.get('name')
    picture = user_info.get('picture')
    
    # Return combined data
    return {
        "id": user_info.get("sub"),  # Google's user ID
        "email": email,
        "name": name,
        "picture": picture,
        "access_token": token_response.get("access_token"),
        "refresh_token": token_response.get("refresh_token"),
        "id_token": token_response.get("id_token"),
        "token_expiry": token_expiry.isoformat(),
        "oauth_provider": "google"
    }


async def refresh_access_token(client_id: str, client_secret: str, refresh_token: str) -> Dict[str, Any]:
    """Refresh an expired access token.
    
    Args:
        client_id: Google OAuth client ID
        client_secret: Google OAuth client secret
        refresh_token: OAuth refresh token
        
    Returns:
        Dictionary containing new token data
    """
    payload = {
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token"
    }
    
    async with httpx.AsyncClient() as client:
        response = await client.post(GOOGLE_TOKEN_URL, data=payload)
        
        if response.status_code != 200:
            logger.error(f"Token refresh failed: {response.text}")
            raise ValueError(f"Failed to refresh token: {response.text}")
            
        return response.json()