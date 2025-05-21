
 
from fastapi import APIRouter, Request, Depends, Query, Response
from authlib.integrations.starlette_client import OAuth, OAuthError
import os
from pathlib import Path
import json
from fastapi.responses import  JSONResponse
from . import get_current_token, get_api_key, hybrid_auth
import percolate as p8
import typing
from fastapi.responses import RedirectResponse
from percolate.utils import logger
from datetime import time,datetime
from percolate.models import User
from percolate.utils import make_uuid
from .utils import extract_user_info_from_token, store_user_with_token,decode_jwt_token
import uuid
from datetime import timezone
      
router = APIRouter()
@router.get("/ping")
async def ping(request: Request, user_id: typing.Optional[str] = Depends(hybrid_auth)):
    """Ping endpoint to verify authentication (bearer token or session)"""
    session_id = request.session.get('session_id')
    if user_id:
        return {
            "message": "pong", 
            "user_id": user_id, 
            "auth_type": "session",
            "session_id": session_id
        }
    else:
        return {"message": "pong", "auth_type": "bearer"}

 
REDIRECT_URI = "http://127.0.0.1:5000/auth/google/callback"# if not project_name else f"https://{project_name}.percolationlabs.ai/auth/google/callback"
SCOPES = [
    'openid',
    'email',
    'profile',
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/drive.readonly',
    'https://www.googleapis.com/auth/documents.readonly'
]
SCOPES = " ".join(SCOPES)

GOOGLE_TOKEN_PATH = Path.home() / '.percolate' / 'auth' / 'google' / 'token'

goauth = OAuth()
goauth.register(
    name='google',
    client_id=os.getenv("GOOGLE_CLIENT_ID"),
    client_secret=os.getenv("GOOGLE_CLIENT_SECRET"),
    authorize_url="https://accounts.google.com/o/oauth2/auth",
    access_token_url="https://oauth2.googleapis.com/token",
    client_kwargs={"scope": SCOPES},
    jwks_uri="https://www.googleapis.com/oauth2/v3/certs"
)



@router.get("/internal-callback")
async def internal_callback(request: Request, token:str=None):
    if token:
        """from our redirect"""
        return Response(json.dumps({'message':'ok'}))
    return Response(json.dumps({'message':'not ok'}))
    
    
    
@router.get("/google/login")
async def login_via_google(request: Request, redirect_uri: typing.Optional[str] = Query(None), sync_files: bool = Query(False)):
    """
    Begin Google OAuth login. Saves client redirect_uri (e.g. custom scheme) in session,
    but only sends registered backend URI to Google.
    
    Args:
        redirect_uri: Optional redirect URI for client apps to receive the token
        sync_files: If True, requests additional scopes for file sync and ensures offline access
    """
    # Save client's requested redirect_uri (e.g. shello://auth) to session
    if redirect_uri:
        request.session["app_redirect_uri"] = redirect_uri
    
    # Store sync_files parameter in session for callback handling
    request.session["sync_files"] = sync_files
        
    callback_url = str(request.url_for("google_auth_callback"))
    """hack because otherwise i need to setup some stuff"""
    
    """any localhost or 127.0.0.1 would be fine here but we will do it the other way for now"""
    if 'percolationlabs.ai' in callback_url:
        callback_url = callback_url.replace(f"http://", "https://")
    
    logger.info(callback_url)
    google = goauth.create_client('google')

    # Log current session state for debugging
    logger.info(f"Session keys before OAuth redirect: {list(request.session.keys())}")
    
    # Special handling for re-login attempts
    # If we already have a token in the session, this is a re-login
    if 'token' in request.session:
        logger.info("Re-login detected - clearing session for fresh OAuth flow")
        # Keep only the app_redirect_uri and sync_files if they were just set
        temp_redirect = request.session.get('app_redirect_uri')
        temp_sync = request.session.get('sync_files', False)
        
        # Clear the entire session
        request.session.clear()
        
        # Restore the values we need
        if temp_redirect:
            request.session['app_redirect_uri'] = temp_redirect
        request.session['sync_files'] = temp_sync
    
    # Clear any OAuth-related state patterns
    keys_to_remove = []
    for key in list(request.session.keys()):
        if key.startswith('_'):  # OAuth states start with underscore
            keys_to_remove.append(key)
    
    for key in keys_to_remove:
        logger.info(f"Removing OAuth key: {key}")
        del request.session[key]
    
    # Always request offline access (even if not syncing files) to get refresh token
    return await google.authorize_redirect(
        request,
        callback_url,  # Must be registered in Google Console -> REDIRECT_URI = "http://127.0.0.1:5000/auth/google/callback"
        scope=SCOPES,
        prompt="consent",
        access_type="offline",  # This is key for getting a refresh token
        include_granted_scopes="true"
    )



@router.get("/google/callback",  name="google_auth_callback")
async def google_auth_callback(request: Request, token:str=None):
    """
    Handle Google OAuth callback. Extracts token, optionally persists it,
    and redirects to original app URI with token as a query param.
    
    If sync_files was requested, also stores credentials in the database for file sync.
    """
    
    if token:
        """from our redirect"""
        return Response(json.dumps({'message':'ok'}))
    
    # Use app-provided redirect_uri (custom scheme) if previously stored
    if request.session.get('app_redirect_uri'):
        """we just write back to the expected callback and rewrite the token however we like - for now a relay"""
        app_redirect_uri = request.session.get("app_redirect_uri")
        # Only remove after we're done with it, at the end of the function
    else:
        app_redirect_uri = None
        
    # Get sync_files preference
    sync_files = request.session.get('sync_files', False)
        
    # Log session state at callback
    logger.info(f"Session keys at callback start: {list(request.session.keys())}")
    logger.info(f"Query params: state={request.query_params.get('state')}, code={request.query_params.get('code')}")
    
    # Debug: Check for OAuth state in session
    oauth_states = [k for k in request.session.keys() if k.startswith('_state_google_')]
    logger.info(f"OAuth states in session: {oauth_states}")
    
    google = goauth.create_client('google')
    
    try:
        token = await google.authorize_access_token(request)
    except OAuthError as e:
        if "mismatching_state" in str(e):
            return JSONResponse(
                status_code=460,  # Custom error code
                content={
                    "error": "CSRF token mismatch",
                    "detail": "mismatching_state - Delete cookies and retry login."
                }
            )
        else:
            logger.error(f"OAuth error: {str(e)}")
            return JSONResponse(
                status_code=400, 
                content={
                    "error": "OAuth authentication failed",
                    "detail": str(e)
                }
            )
    except Exception as e:
        logger.error(f"Unexpected error during OAuth: {str(e)}")
        logger.error(f"Session keys: {list(request.session.keys())}")
        logger.error(f"Session ID: {request.session.get('session_id')}")
        
        return JSONResponse(
            status_code=500, 
            content={
                "error": "Internal server error during authentication",
                "detail": str(e)
            }
        )

    # Save token in session (optional)
    request.session['token'] = token

    # Persist token for debugging or dev use (optional)
    GOOGLE_TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(GOOGLE_TOKEN_PATH, 'w') as f:
        json.dump(token, f)
    
    # If this authentication is for file sync, store credentials in database
    #will deprecate this to unify with other creds
    if sync_files and "refresh_token" in token:
        try:
            # Use the FileSync service to store OAuth credentials
            from percolate.services.sync.file_sync import FileSync
            await FileSync.store_oauth_credentials(token)
        except Exception as e:
            logger.error(f"Error storing sync credentials: {str(e)}")

    # Create a unique session ID and store it in the session
    session_id = str(uuid.uuid4())
    request.session['session_id'] = session_id
    logger.info(f"Created new session with ID: {session_id}")
    
    # Store the user with token and session
    user = store_user_with_token(token, session_id)
    logger.info(f"Stored user: {user.email} with session: {session_id}")
 
    id_token = token.get("id_token")
    if not id_token:
        return JSONResponse(status_code=400, content={"error": "No id_token found"})

    # Clean up temporary session data before returning
    if 'app_redirect_uri' in request.session:
        del request.session['app_redirect_uri']
    if 'sync_files' in request.session:
        del request.session['sync_files']
    
    if app_redirect_uri:
        logger.debug(f'im redirecting to {app_redirect_uri=} with the token')
        redirect_url = f"{app_redirect_uri}?token={id_token}" ##used to out the token here but its too big so testing without 
        return RedirectResponse(redirect_url)
    
    return Response(json.dumps({'token':id_token}))

    # NOTE: Later, replace this logic with:
    #  - Validate Google's id_token server-side
    #  - Issue our own short-lived app token (e.g., JWT)
    #  - Set secure HttpOnly cookie or return token in redirect or JSON response
    
@router.get("/session/info")
async def session_info(request: Request, user_id: typing.Optional[str] = Depends(hybrid_auth)):
    """Get current session information including user profile data"""
    session_data = dict(request.session)
    session_cookie = request.cookies.get('session')
    
    # Start with basic session info
    response_data = {
        "user_id": user_id,
        "session_id": session_data.get('session_id'),
        "session_cookie_present": bool(session_cookie),
        "session_data_keys": list(session_data.keys()),
        "auth_type": "session" if user_id else "none"
    }
    
    # If we have a user_id, get their profile info from the database
    if user_id:
        try:
            user = p8.repository(User).select(id=user_id) 
            if user:
                user = User(**user[0])
            if user and user.token:
                # Extract user info from the stored token
                user_info = extract_user_info_from_token(user.token)
                
                # Get complete token data for userinfo
                token_data = {}
                id_token_data = {}
                try:
                    import json
                    if isinstance(user.token, str) and user.token.startswith('{'):
                        # Full OAuth token stored as JSON
                        token_data = json.loads(user.token)
                        
                        # Also decode the id_token for additional info
                        if 'id_token' in token_data:
                            id_token_data = decode_jwt_token(token_data['id_token'])
                    else:
                        # Just an ID token string stored
                        id_token_data = decode_jwt_token(user.token)
                except Exception as e:
                    logger.error(f"Error parsing token data: {str(e)}")
                
                # Combine all available user info from various sources
                response_data.update({
                    "user_info": {
                        "id": str(user.id),
                        "email": user.email or user_info[1] or id_token_data.get('email'),
                        "name": user.name or id_token_data.get('name'),
                        "given_name": id_token_data.get('given_name'),
                        "family_name": id_token_data.get('family_name'),
                        "picture": id_token_data.get('picture'),
                        "verified": id_token_data.get('email_verified'),
                        "locale": id_token_data.get('locale'),
                        "hd": id_token_data.get('hd'),  # Hosted domain for Google Workspace
                        "token_expiry": user.token_expiry.isoformat() if user.token_expiry else None,
                        "last_session_at": user.last_session_at.isoformat() if user.last_session_at else None,
                        "oauth_provider": "google",  # Hardcoded for now since we only support Google
                        "scopes": token_data.get('scope', '').split() if 'scope' in token_data else []
                    }
                })
        except Exception as e:
            logger.error(f"Error fetching user info: {str(e)}")
    
    return response_data


@router.get("/session/debug")
async def session_debug(request: Request):
    """Debug endpoint to see raw session data"""
    session_cookie = request.cookies.get('session')
    
    # Get raw session data
    session_data = {}
    try:
        session_data = dict(request.session)
    except Exception as e:
        session_data = {"error": str(e)}
    
    return {
        "cookies": dict(request.cookies),
        "session_cookie_present": bool(session_cookie),
        "session_cookie_length": len(session_cookie) if session_cookie else 0,
        "session_data": session_data,
        "session_keys": list(session_data.keys()) if isinstance(session_data, dict) else [],
        "headers": dict(request.headers)
    }


@router.get("/connect")
async def fetch_percolate_project(token = Depends(get_current_token)):
    """Connect with your key to get percolate project settings and keys.
     These settings can be used in the percolate cli e.g. p8 connect <project_name> --token <token>
    """
    
    project_name = p8.settings('NAME')
    """hard coded for test accounts for now"""
    port = 5432
    if project_name == 'rajaas':
        port = 5433
    if project_name == 'devansh':
        port = 5434 
 
    return {
        'NAME': project_name,
        'USER': p8.settings('USER') or (project_name),
        'PASSWORD': p8.settings('PASSWORD', token),
        'P8_PG_DB': 'app',
        'P8_PG_USER': p8.settings('P8_PG_USER', 'postgres'),
        'P8_PG_PORT': port,  #p8.settings('P8_PG_PORT', 5433), #<-this must be set via a config map for the ingress for the database and requires an LB service
        'P8_PG_PASSWORD':  token,
        'BUCKET_SECRET': None, #permissions are added for blob/project/ for the user
        'P8_PG_HOST' : p8.settings('P8_PG_HOST', f'{project_name}.percolationlabs.ai')    
    }
    
    
    
#     kubectl patch ingress percolate-api-ingress \
#   -n eepis \
#   --type='merge' \
#   -p '{
#     "metadata": {
#       "annotations": {
#         "nginx.ingress.kubernetes.io/proxy-buffer-size": "16k",
#         "nginx.ingress.kubernetes.io/proxy-buffers-number": "8",
#         "nginx.ingress.kubernetes.io/proxy-buffering": "on"
#       }
#     }
#   }'