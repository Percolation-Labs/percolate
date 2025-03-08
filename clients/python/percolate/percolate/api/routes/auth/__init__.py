from fastapi import Depends, FastAPI, Header, HTTPException, UploadFile
from typing import Annotated, List
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from percolate.utils.env import load_db_key

from .router import router

bearer = HTTPBearer()
async def get_current_token(
    credentials: HTTPAuthorizationCredentials = Depends(bearer),
):
    token = credentials.credentials

    if token != load_db_key("P8_API_KEY"):
        raise HTTPException(
            status_code=401,
            detail="Invalid API KEY in token check.",
        )

    return token