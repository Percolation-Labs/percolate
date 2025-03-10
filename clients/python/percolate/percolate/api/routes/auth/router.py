
 
from fastapi import APIRouter, HTTPException
 
import uuid
from fastapi import   Depends
from pydantic import BaseModel

router = APIRouter()

#https://docs.authlib.org/en/latest/client/starlette.html
@app.get("/auth/google/login")
async def login_via_google(request: Request):
    redirect_uri = REDIRECT_URI
    google = oauth.create_client('google')
 
    return await google.authorize_redirect(request, redirect_uri)

@app.get("/auth/google/callback")
async def auth_callback(request: Request):
    google = oauth.create_client('google')
    token = await google.authorize_access_token(request)
    request.session['token'] = token
    TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(TOKEN_PATH, 'w') as f:
        json.dump(token, f)
    userinfo = token['userinfo']

    return JSONResponse(content={"token": token, "user_info": userinfo})