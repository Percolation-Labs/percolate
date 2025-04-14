from fastapi import Depends, FastAPI, Header, HTTPException, UploadFile
from typing import Annotated, List
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from percolate.utils.env import load_db_key, POSTGRES_PASSWORD


bearer = HTTPBearer()


"""
Playing with different keys here. The TOKEN should be strict as its a master key
The other token is softer and it can be used to confirm comms between the database and the API but we dont necessarily want to store the master key in the same place.

"""

def get_api_key(
    credentials: HTTPAuthorizationCredentials = Depends(bearer),
):
    token = credentials.credentials

    """we should allow the API_TOKEN which can be lower security i.e. allow some users to use without providing keys to the castle"""
    """TODO single and multi ten auth"""
    if token != load_db_key('P8_API_KEY') or token != POSTGRES_PASSWORD:
        raise HTTPException(
            status_code=401,
            detail="Invalid API KEY in token check.",
        )

    return token


def get_current_token(
    credentials: HTTPAuthorizationCredentials = Depends(bearer),
):
    token = credentials.credentials

    """we should allow the API_TOKEN which can be lower security i.e. allow some users to use without providing keys to the castle"""
    """TODO single and multi ten auth"""
    if token != POSTGRES_PASSWORD:
        raise HTTPException(
            status_code=401,
            detail="Invalid API KEY in token check.",
        )

    return token

from .router import router