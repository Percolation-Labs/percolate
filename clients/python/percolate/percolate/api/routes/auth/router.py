from fastapi import APIRouter, Request, Depends, Query, Response
import os
from pathlib import Path
import json
from fastapi.responses import JSONResponse
from . import get_current_token, get_api_key, hybrid_auth
import percolate as p8
import typing
from fastapi.responses import RedirectResponse
from percolate.utils import logger
from datetime import datetime, timezone, timedelta
from percolate.models import User
from percolate.utils import make_uuid
from .utils import extract_user_info_from_token, store_user_with_token, decode_jwt_token, get_stable_session_key
import uuid
import base64
from .google_oauth import GoogleOAuth, extract_user_info
      
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

 
# Define Google OAuth scopes
SCOPES = [
    'openid',
    'email',
    'profile',
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/calendar.readonly',
    'https://www.googleapis.com/auth/drive.readonly',
    'https://www.googleapis.com/auth/documents.readonly'
]

GOOGLE_TOKEN_PATH = Path.home() / '.percolate' / 'auth' / 'google' / 'token'

# Create Google OAuth client
google_oauth = GoogleOAuth(
    client_id=os.getenv("GOOGLE_CLIENT_ID"),
    client_secret=os.getenv("GOOGLE_CLIENT_SECRET"),
    scopes=SCOPES
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
    # Create a new session ID
    session_id = str(uuid.uuid4())
    logger.info(f"Generated new session ID for OAuth: {session_id}")
    request.session.setdefault("session_id", session_id)
    
    # Ensure cookies are set for the domain
    request.session.setdefault("_session_created", datetime.now().isoformat())
    
    # Save client's requested redirect_uri (e.g. shello://auth) to session
    if redirect_uri:
        logger.info(f"LOGIN: Saving app redirect URI to session: {redirect_uri}")
        request.session["app_redirect_uri"] = redirect_uri
    else:
        logger.info("LOGIN: No app redirect URI provided")
    
    # Store sync_files parameter in session for callback handling
    request.session["sync_files"] = sync_files
    
    # Log all session data for debugging
    logger.info(f"LOGIN: Session after storing redirect URI: {dict(request.session)}")
    
    # IMPORTANT: There are two different redirect URIs involved
    # 1. oauth_callback_url: The URL registered with Google (MUST match exactly in both OAuth steps)
    # 2. app_redirect_uri: Where to redirect the user after authentication (client app specific)
    
    # Get the OAuth callback URL - this is CRITICAL for OAuth to work correctly
    # This must EXACTLY match what's registered in Google Cloud Console
    oauth_callback_url = str(request.url_for("google_auth_callback"))
    
    # Normalize the URL for consistent behavior
    # - Replace http:// with https:// for production domains
    # - Keep port information consistent (strip it for standard ports)
    
    original_callback = oauth_callback_url  # Save for logging
    
    if 'percolationlabs.ai' in oauth_callback_url:
        # Force HTTPS for production domains
        oauth_callback_url = oauth_callback_url.replace("http://", "https://")
        
        # Log for debugging
        if original_callback != oauth_callback_url:
            logger.info(f"Converted OAuth callback URL from {original_callback} to {oauth_callback_url}")
    
    # Remove default ports if present (helps with matching)
    oauth_callback_url = oauth_callback_url.replace(":443/", "/").replace(":80/", "/")
    
    # Store the exact OAuth callback URL in session for later use with token exchange
    request.session["oauth_callback_url"] = oauth_callback_url
    
    # The app_redirect_uri is handled separately and stored in request.session["app_redirect_uri"]
    # That's for redirecting the user AFTER OAuth completes
    
    logger.info(f"Using OAuth callback URL: {oauth_callback_url}")
    logger.info(f"Client app redirect URI: {request.session.get('app_redirect_uri')}")
    
    # Log session cookie for debugging
    logger.info(f"Current session cookie: {request.cookies.get('session')}")

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
    
    # Create a state parameter that includes the redirect URI
    # Format: [random-uuid]|[redirect-uri]
    # This allows us to recover the redirect URI even if the session is lost
    base_state = str(uuid.uuid4())
    redirect_data = request.session.get("app_redirect_uri", "")
    
    # Combine state and redirect URI in a way we can parse later
    combined_state = f"{base_state}|{redirect_data}"
    
    # Store in session
    request.session["oauth_state"] = combined_state
    
    # Log what we're planning to do
    logger.info(f"Generated new OAuth state with embedded redirect: {combined_state}")
    logger.info(f"Session after state setup: {list(request.session.keys())}")
    
    # Generate authorization URL with our combined state
    authorization_url = google_oauth.get_authorization_url(
        redirect_uri=oauth_callback_url,
        state=combined_state
    )
    
    # Redirect user to Google's authorization endpoint
    return RedirectResponse(authorization_url)


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
    logger.info(f"CALLBACK: All session keys: {list(request.session.keys())}")
    logger.info(f"CALLBACK: Full session data: {dict(request.session)}")
    
    if request.session.get('app_redirect_uri'):
        """we just write back to the expected callback and rewrite the token however we like - for now a relay"""
        app_redirect_uri = request.session.get("app_redirect_uri")
        logger.info(f"CALLBACK: Found app_redirect_uri in session: {app_redirect_uri}")
        # Only remove after we're done with it, at the end of the function
    else:
        logger.info("CALLBACK: No app_redirect_uri found in session!")
        app_redirect_uri = None
        
    # Get sync_files preference
    sync_files = request.session.get('sync_files', False)
        
    # Log session state at callback
    logger.info(f"Session keys at callback start: {list(request.session.keys())}")
    logger.info(f"Query params: state={request.query_params.get('state')}, code={request.query_params.get('code')}")
    
    # Log raw cookie data for debugging
    if 'session' in request.cookies:
        cookie_value = request.cookies.get('session')
        # Try to decode the base64 part of the cookie to see what's inside
        try:
            # The cookie format is typically: value.timestamp.signature
            # The value is base64 encoded
            if '.' in cookie_value:
                base64_part = cookie_value.split('.')[0]
                try:
                    decoded = base64.b64decode(base64_part).decode('utf-8')
                    logger.info(f"Decoded cookie content: {decoded}")
                except:
                    logger.error(f"Failed to decode cookie content")
        except Exception as e:
            logger.error(f"Error examining cookie: {e}")
    
    # Get the authorization code and state from the request
    code = request.query_params.get('code')
    returned_state = request.query_params.get('state')
    
    if not code:
        logger.error("No authorization code found in request")
        return JSONResponse(
            status_code=400,
            content={"error": "No authorization code found in request"}
        )
    
    # Extract redirect URI from the returned state parameter
    # Format is [random-uuid]|[redirect-uri]
    extracted_redirect_uri = None
    if returned_state and '|' in returned_state:
        state_parts = returned_state.split('|', 1)
        base_state = state_parts[0]
        extracted_redirect_uri = state_parts[1] if len(state_parts) > 1 else None
        logger.info(f"Extracted redirect URI from state: {extracted_redirect_uri}")
        
        # If we have a valid redirect URI from the state, use it
        if extracted_redirect_uri and extracted_redirect_uri.strip():
            app_redirect_uri = extracted_redirect_uri
            logger.info(f"Using redirect URI from state parameter: {app_redirect_uri}")
    
    # Get the state from the session
    original_state = request.session.get('oauth_state')
    
    # If session lost but URL contains state, try to recover from cookie
    if not original_state and 'session' in request.cookies:
        try:
            cookie_value = request.cookies.get('session')
            if '.' in cookie_value:
                base64_part = cookie_value.split('.')[0]
                decoded = base64.b64decode(base64_part).decode('utf-8')
                # Try to parse as JSON
                cookie_data = json.loads(decoded)
                if 'oauth_state' in cookie_data:
                    original_state = cookie_data['oauth_state']
                    logger.info(f"Recovered original state from cookie: {original_state}")
        except Exception as e:
            logger.error(f"Error recovering state from cookie: {e}")
    
    # Verify the base state for CSRF protection
    # We only compare the UUID part before the pipe symbol
    original_base_state = original_state.split('|')[0] if original_state and '|' in original_state else original_state
    returned_base_state = returned_state.split('|')[0] if returned_state and '|' in returned_state else returned_state
    
    if not original_base_state or not returned_base_state or original_base_state != returned_base_state:
        logger.warning(f"State mismatch: original={original_base_state}, returned={returned_base_state}")
        # Continue anyway for now - state mismatch might be due to session problems
        # In production, you should handle this more securely
    
    # Get the OAuth callback URL from session
    oauth_callback_url = request.session.get('oauth_callback_url')
    
    # If oauth_callback_url not found in session, try to recover from cookie
    if not oauth_callback_url and 'session' in request.cookies:
        try:
            cookie_value = request.cookies.get('session')
            if '.' in cookie_value:
                base64_part = cookie_value.split('.')[0]
                decoded = base64.b64decode(base64_part).decode('utf-8')
                # Try to parse as JSON
                cookie_data = json.loads(decoded)
                if 'oauth_callback_url' in cookie_data:
                    oauth_callback_url = cookie_data['oauth_callback_url']
                    logger.info(f"Recovered oauth_callback_url from cookie: {oauth_callback_url}")
        except Exception as e:
            logger.error(f"Error recovering oauth_callback_url from cookie: {e}")
    
    # If still no OAuth callback URL, use the current one
    if not oauth_callback_url:
        # This must match what's registered with Google
        oauth_callback_url = str(request.url_for("google_auth_callback"))
        if 'percolationlabs.ai' in oauth_callback_url:
            oauth_callback_url = oauth_callback_url.replace("http://", "https://")
        # Remove default ports if present (helps with matching)
        oauth_callback_url = oauth_callback_url.replace(":443/", "/").replace(":80/", "/")
        logger.info(f"Using current URL as OAuth callback: {oauth_callback_url}")
    
    try:
        # Exchange authorization code for token
        token_data = await google_oauth.exchange_code_for_token(code, oauth_callback_url)
        logger.info("Successfully obtained token from Google")
        
        # Get user information
        access_token = token_data.get('access_token')
        if not access_token:
            logger.error("No access token found in response")
            return JSONResponse(
                status_code=400,
                content={"error": "No access token found in response"}
            )
        
        # Get user info using access token
        user_info = await google_oauth.get_user_info(access_token)
        logger.info(f"Retrieved user info: {user_info.get('email')}")
        
        # Combine token and user info
        combined_info = extract_user_info(token_data, user_info)
        
        # Save token in session
        request.session['token'] = token_data
        
        # Persist token for debugging or dev use (optional)
        GOOGLE_TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(GOOGLE_TOKEN_PATH, 'w') as f:
            json.dump(token_data, f)
        
        # If this authentication is for file sync, store credentials in database
        #will deprecate this to unify with other creds
        if sync_files and "refresh_token" in token_data:
            try:
                # Use the FileSync service to store OAuth credentials
                from percolate.services.sync.file_sync import FileSync
                await FileSync.store_oauth_credentials(token_data)
            except Exception as e:
                logger.error(f"Error storing sync credentials: {str(e)}")
        
        # Get the actual session cookie value to use as session_id for database lookups
        # This ensures we can find the user by their session cookie
        session_cookie = request.cookies.get('session')
        if session_cookie:
            # The session cookie is the actual session identifier used by SessionMiddleware
            session_id = session_cookie
            logger.info(f"Using session cookie as session_id: {session_id[:10]}...")
        else:
            # Fallback to creating a new ID if no session cookie exists
            session_id = str(uuid.uuid4())
            logger.info(f"No session cookie found, created new session_id: {session_id}")
        
        # Store the user with token and session
        user = store_user_with_token(token_data, session_id)
        logger.info(f"Stored user: {user.email} with session: {session_id}")
        
        # Store user information in the session for easy retrieval
        request.session['user_id'] = str(user.id)
        request.session['email'] = user.email
        request.session['name'] = user.name
        logger.info(f"Stored user info in session: user_id={user.id}, email={user.email}")
        
        id_token = token_data.get("id_token")
        if not id_token:
            return JSONResponse(status_code=400, content={"error": "No id_token found"})
        
        # Clean up temporary session data - BUT KEEP app_redirect_uri until after redirection
        # We'll only remove it if we're not redirecting
        if 'sync_files' in request.session:
            del request.session['sync_files']
        if 'oauth_state' in request.session:
            del request.session['oauth_state']
        if 'oauth_callback_url' in request.session:
            del request.session['oauth_callback_url']
            
        logger.info("CALLBACK: Preserved app_redirect_uri for redirection")
        
        # Final check before redirecting
        logger.info(f"CALLBACK FINAL: app_redirect_uri = {app_redirect_uri}")
        logger.info(f"CALLBACK FINAL: Remaining session keys: {list(request.session.keys())}")
        
        if app_redirect_uri:
            logger.info(f'REDIRECTING to {app_redirect_uri} with token')
            redirect_url = f"{app_redirect_uri}?token={id_token}"
            logger.info(f'Full redirect URL: {redirect_url}')
            
            # Now that we're about to redirect, we can remove app_redirect_uri from session
            if 'app_redirect_uri' in request.session:
                del request.session['app_redirect_uri']
                logger.info("Removed app_redirect_uri from session after preparing redirect")
            
            # Using 303 See Other for redirection after POST
            return RedirectResponse(url=redirect_url, status_code=303)
        else:
            logger.info('Not redirecting, returning token as JSON response')
            
            # Clean up app_redirect_uri if somehow it's still in the session
            if 'app_redirect_uri' in request.session:
                del request.session['app_redirect_uri']
                logger.info("Removed app_redirect_uri from session (no redirect case)")
                
            return Response(json.dumps({'token': id_token}))
        
    except Exception as e:
        logger.error(f"Error during OAuth token exchange or user info retrieval: {str(e)}")
        return JSONResponse(
            status_code=500,
            content={
                "error": "OAuth authentication failed",
                "detail": str(e)
            }
        )


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
                
                # Include Google OAuth tokens if available
                if token_data:
                    response_data["google_tokens"] = {
                        "access_token": token_data.get("access_token"),
                        "refresh_token": token_data.get("refresh_token"),
                        "expires_in": token_data.get("expires_in"),
                        "expires_at": token_data.get("expires_at"),
                        "token_type": token_data.get("token_type", "Bearer")
                    }
                
                # Also check if we have stored sync credentials
                try:
                    from percolate.models.sync import SyncCredential
                    sync_creds = p8.repository(SyncCredential).select(userid=user_id)
                    if sync_creds:
                        cred = SyncCredential(**sync_creds[0])
                        response_data["sync_credentials"] = {
                            "access_token": cred.access_token,
                            "refresh_token": cred.refresh_token,
                            "expires_at": cred.token_expiry.isoformat() if cred.token_expiry else None,
                            "provider": cred.provider
                        }
                except Exception as e:
                    logger.debug(f"No sync credentials found: {e}")
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