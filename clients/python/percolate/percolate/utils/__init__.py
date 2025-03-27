import json
import hashlib
import uuid
from . import names
from loguru import logger
from pathlib import Path
import os
from .env import get_repo_root
 
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

    return str(uuid.uuid5(uuid.NAMESPACE_DNS   , input_object))


def batch_collection(collection, batch_size):
    """Yield successive batches of size batch_size from collection. can also be used to chunk string of chars"""
    for i in range(0, len(collection), batch_size):
        yield collection[i : i + batch_size]
        

    
def split_string_into_chunks(string, chunk_size=20000):
    """simple chunker"""
    return [string[i : i + chunk_size] for i in range(0, len(string), chunk_size)]
