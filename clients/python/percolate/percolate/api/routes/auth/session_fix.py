"""
Session persistence fix for OAuth state issues
"""

from starlette.sessions import SessionMiddleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
import json
import os
from pathlib import Path
from typing import Dict, Any

class PersistentSessionMiddleware(BaseHTTPMiddleware):
    """
    A middleware that provides persistent file-based sessions.
    This is a temporary fix for OAuth state issues.
    """
    
    def __init__(self, app, session_dir: str = None):
        super().__init__(app)
        self.session_dir = session_dir or os.path.expanduser("~/.percolate/sessions")
        Path(self.session_dir).mkdir(parents=True, exist_ok=True)
    
    async def dispatch(self, request: Request, call_next):
        # Get session ID from cookie or create new one
        session_id = request.cookies.get("session_id")
        
        if not session_id:
            import uuid
            session_id = str(uuid.uuid4())
        
        # Load session data
        session_file = os.path.join(self.session_dir, f"{session_id}.json")
        session_data = {}
        
        if os.path.exists(session_file):
            try:
                with open(session_file, 'r') as f:
                    session_data = json.load(f)
            except:
                pass
        
        # Attach session to request
        request.state.session = session_data
        request.state.session_id = session_id
        
        # Process request
        response = await call_next(request)
        
        # Save session data
        try:
            with open(session_file, 'w') as f:
                json.dump(request.state.session, f)
        except:
            pass
        
        # Set session cookie
        response.set_cookie(
            key="session_id",
            value=session_id,
            httponly=True,
            secure=False,  # Set to True in production with HTTPS
            samesite="lax",
            max_age=86400  # 24 hours
        )
        
        return response

def get_session_with_retry(request: Request) -> Dict[str, Any]:
    """
    Get session data with fallback to persistent storage if in-memory session is empty.
    """
    # First try the standard session
    if hasattr(request, 'session') and request.session:
        return request.session
    
    # Fallback to state session
    if hasattr(request.state, 'session'):
        return request.state.session
    
    # Return empty dict as last resort
    return {}