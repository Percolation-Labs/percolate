
 
from fastapi import APIRouter, Request
from authlib.integrations.starlette_client import OAuth
import os
from pathlib import Path
import json
from fastapi.responses import  JSONResponse
router = APIRouter()


REDIRECT_URI = "http://127.0.0.1:5000/auth/google/callback"
SCOPES = "openid email profile https://www.googleapis.com/auth/gmail.readonly"
TOKEN_PATH = Path.home() / '.percolate' / 'auth' / 'token'

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


#https://docs.authlib.org/en/latest/client/starlette.html
@router.get("/google/login")
async def login_via_google(request: Request):
    """use google oauth to login if this is the users preference"""
    redirect_uri = REDIRECT_URI
    google = goauth.create_client('google')
    return await google.authorize_redirect(
        request, redirect_uri, scope=SCOPES
    )

@router.get("/google/callback")
async def google_auth_callback(request: Request):
    """a callback from the oauth flow"""
    google = goauth.create_client('google')
    token = await google.authorize_access_token(request)
    request.session['token'] = token
    TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(TOKEN_PATH, 'w') as f:
        json.dump(token, f)
    userinfo = token['userinfo']

    return JSONResponse(content={"token": token, "user_info": userinfo})