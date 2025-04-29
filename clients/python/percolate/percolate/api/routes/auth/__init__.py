from fastapi import Depends, FastAPI, Header, HTTPException, UploadFile
from typing import Annotated, List
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from percolate.utils.env import load_db_key, POSTGRES_PASSWORD
from percolate.utils import logger

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
    key = load_db_key('P8_API_KEY')
    if token != key and token != POSTGRES_PASSWORD:
        logger.warning(f"Failing to connect using token {token[:3]}..{token[-3:]} - expecting either {key[:3]}..{key[-3:]} or {POSTGRES_PASSWORD[:3]}..{POSTGRES_PASSWORD[-3:]}")
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
    
    #print('compare', token, POSTGRES_PASSWORD) -> prints are not logged k8s and good for debugging
    
    if token != POSTGRES_PASSWORD:
        raise HTTPException(
            status_code=401,
            detail="Invalid API KEY in token check.",
        )

    return token

from .router import router