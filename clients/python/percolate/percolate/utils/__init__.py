import json
import hashlib
import uuid
from . import names
from loguru import logger
from pathlib import Path
import os
from .env import get_repo_root
import datetime
from datetime import timedelta, timezone
import base64
import json

def try_parse_base64_dict(base64_data:str)->dict:
    try:
        return parse_base64_dict(base64_data=base64_data)
    except:
        """ignore errors"""
        pass
    
def parse_base64_dict(base64_data:str)->dict:
    """we encoded arbitrary device data which can be decoded to a dict"""


    if base64_data:
        try: 
            decoded_bytes = base64.b64decode(base64_data) 
            decoded_str = decoded_bytes.decode('utf-8') 
            return json.loads(decoded_str)
        except Exception:
            logger.debug(f"Failing to parse base64 data {base64_data} to a dict")
            raise

    return None
    
    
def get_iso_timestamp():
    """
    Returns the current time as an ISO 8601 formatted string with second precision.
    
    Returns:
        str: ISO formatted timestamp (YYYY-MM-DDTHH:MM:SS)
    """
    now = datetime.datetime.now()
    return now.isoformat()

def get_days_ago_iso_timestamp(n=1):
    """
    Returns the current time as an ISO 8601 formatted string with second precision.
    
    Returns:
        str: ISO formatted timestamp (YYYY-MM-DDTHH:MM:SS)
    """
    dt_24h_ago = datetime.datetime.now(timezone.utc) - timedelta(days=n)
    return dt_24h_ago.isoformat()

def uuid_str_from_dict(d):
    """
    generate a uuid string from a seed that is a sorted dict
    """
    m = hashlib.md5()
    m.update(json.dumps(d, sort_keys=True).encode("utf-8"))
    return str(uuid.UUID(m.hexdigest()))


def make_uuid(input_object: str | dict):
    """
    make a uuid from input
    """

    if isinstance(input_object, dict):
        return uuid_str_from_dict(input_object)

    return str(uuid.uuid5(uuid.NAMESPACE_DNS, input_object))


def batch_collection(collection, batch_size):
    """Yield successive batches of size batch_size from collection. can also be used to chunk string of chars"""
    for i in range(0, len(collection), batch_size):
        yield collection[i : i + batch_size]
        

    
def split_string_into_chunks(string, chunk_size=20000):
    """simple chunker"""
    return [string[i : i + chunk_size] for i in range(0, len(string), chunk_size)]

