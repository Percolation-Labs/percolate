import pytest
import typing
from pydantic import BaseModel, Field
import uuid
import datetime
from percolate.models.utils import SqlModelHelper

class C(BaseModel):
    name: str
    
class SampleType(BaseModel):
    id: uuid.UUID | str
    name: str
    category : typing.Optional[str] = Field(json_schema_extra={'varchar_length':100})
    items: typing.List[str]
    labels: typing.List[str] | str
    created_at: datetime.datetime
    metadata: dict
    child: C


def test_typing_mapping():
    """"""
    
    mapping = SqlModelHelper.python_to_postgres_types(SampleType)
    
    expected = {'id': 'UUID',
    'name': 'TEXT',
    'category': 'VARCHAR(100)',
    'items': 'TEXT[]',
    'labels': 'TEXT[]',
    'created_at': 'TIMESTAMP',
    'metadata': 'JSON',
    'child': 'JSON'}
    
    for k,v in expected.items():
        assert v == mapping[k], f"Expected the mapping for field {k} to by {v} but got {mapping[k]}"
        
    