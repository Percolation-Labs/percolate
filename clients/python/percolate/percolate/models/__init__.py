from pydantic import Field
from functools import partial
import typing

def EmbeddedField(embedding_provider='default')->Field:
    return partial(Field, json_schema_extra={'embedding_provider':embedding_provider})

DefaultEmbeddingField = EmbeddedField()

def KeyField():
    return partial(Field, json_schema_extra={'is_key':True})


from . import utils
from .MessageStack import  MessageStack
from .AbstractModel import AbstractModel

def get_p8_models():
    """convenience to load all p8 models in the library"""
    
    from percolate.models.inspection import get_classes
    return get_classes(package="percolate.models.p8")