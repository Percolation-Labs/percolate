
 
from fastapi import APIRouter, Request, Depends, Query
from authlib.integrations.starlette_client import OAuth
import os
from pathlib import Path
import json
from fastapi.responses import  JSONResponse
from . import get_current_token
import percolate as p8
import typing
from fastapi.responses import RedirectResponse

router = APIRouter()


REDIRECT_URI = "http://127.0.0.1:5000/auth/google/callback"
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
    client_id=os.getenv("PD_GOOGLE_CLIENT_ID"),
    client_secret=os.getenv("PD_GOOGLE_CLIENT_SECRET"),
    authorize_url="https://accounts.google.com/o/oauth2/auth",
    access_token_url="https://oauth2.googleapis.com/token",
    client_kwargs={"scope": SCOPES},
    jwks_uri="https://www.googleapis.com/oauth2/v3/certs"
)


# #https://docs.authlib.org/en/latest/client/starlette.html
# @router.get("/google/login")
# async def login_via_google(request: Request, redirect_uri: typing.Optional[str] = Query(None)):
#     """Use Google OAuth to login, allowing optional override of redirect URI."""
#     final_redirect_uri = redirect_uri or REDIRECT_URI
#     google = goauth.create_client('google')
#     return await google.authorize_redirect(
#         request, final_redirect_uri, scope=SCOPES,
#         prompt="consent",           
#         access_type="offline",         
#         include_granted_scopes="true"
#     )
# @router.get("/google/callback")
# async def google_auth_callback(request: Request):
#     """a callback from the oauth flow"""
#     google = goauth.create_client('google')
#     token = await google.authorize_access_token(request)
#     request.session['token'] = token
#     GOOGLE_TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
#     with open(GOOGLE_TOKEN_PATH, 'w') as f:
#         json.dump(token, f)
#     userinfo = token['userinfo']

#     return JSONResponse(content={"token": token, "user_info": userinfo})

@router.get("/google/login")
async def login_via_google(request: Request, redirect_uri: typing.Optional[str] = Query(None)):
    """
    Begin Google OAuth login. Saves client redirect_uri (e.g. custom scheme) in session,
    but only sends registered backend URI to Google.
    """
    # Save client's requested redirect_uri (e.g. shello://auth) to session
    if redirect_uri:
        request.session["app_redirect_uri"] = redirect_uri

    google = goauth.create_client('google')
    return await google.authorize_redirect(
        request,
        REDIRECT_URI,  # Must be registered in Google Console
        scope=SCOPES,
        prompt="consent",
        access_type="offline",
        include_granted_scopes="true"
    )


@router.get("/google/callback")
async def google_auth_callback(request: Request):
    """
    Handle Google OAuth callback. Extracts token, optionally persists it,
    and redirects to original app URI with token as a query param.
    """
    google = goauth.create_client('google')
    token = await google.authorize_access_token(request)

    # Save token in session (optional)
    request.session['token'] = token

    # Persist token for debugging or dev use (optional)
    GOOGLE_TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(GOOGLE_TOKEN_PATH, 'w') as f:
        json.dump(token, f)

    userinfo = token.get("userinfo")
    id_token = token.get("id_token")

    if not id_token:
        return JSONResponse(status_code=400, content={"error": "No id_token found"})

    # TEMPORARY: Use Google's ID token to pass to client. Replace with signed session JWT later.
    # TODO: Replace with server-issued JWT or session mechanism for better security.

    # Use app-provided redirect_uri (custom scheme) if previously stored
    app_redirect_uri = request.session.pop("app_redirect_uri", "shello://auth")
    redirect_url = f"{app_redirect_uri}?token={id_token}"

    return RedirectResponse(redirect_url)

    # NOTE: Later, replace this logic with:
    #  - Validate Google's id_token server-side
    #  - Issue your own short-lived app token (e.g., JWT)
    #  - Set secure HttpOnly cookie or return token in redirect or JSON response
    
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
        'USER': p8.settings('USER',project_name),
        'PASSWORD': p8.settings('PASSWORD', token),
        'P8_PG_DB': 'app',
        'P8_PG_USER': p8.settings('P8_PG_USER', 'postgres'),
        'P8_PG_PORT': port,  #p8.settings('P8_PG_PORT', 5433), #<-this must be set via a config map for the ingress for the database and requires an LB service
        'P8_PG_PASSWORD':  token,
        'BUCKET_SECRET': None, #permissions are added for blob/project/ for the user
        'P8_PG_HOST' : p8.settings('P8_PG_HOST', f'{project_name}.percolationlabs.ai')    
    }