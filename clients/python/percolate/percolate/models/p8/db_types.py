"""keep track of the schema used to return database objects
this will evolve and change plenty in the beginning
"""
from pydantic import BaseModel, Field, model_validator
import typing
import json
import enum
from enum import IntEnum


class AccessLevel(IntEnum):
    """
    Access level definitions for row-level security.
    Lower numbers indicate higher privileges.
    """
    GOD = 0        # Unrestricted access to all data
    ADMIN = 1      # Administrative access
    INTERNAL = 5   # Internal/employee access
    PARTNER = 10   # External partner access
    PUBLIC = 100   # Public access (most restricted)

    @classmethod
    def get_description(cls, level: int) -> str:
        """
        Get a human-readable description of an access level
        
        Args:
            level: The numeric access level
            
        Returns:
            A string description of the access level
        """
        descriptions = {
            cls.GOD: "Unrestricted system-level access",
            cls.ADMIN: "Administrative access",
            cls.INTERNAL: "Internal/employee access",
            cls.PARTNER: "External partner access",
            cls.PUBLIC: "Public access (most restricted)"
        }
        return descriptions.get(level, f"Custom access level: {level}")
"""1 responses from agent calls"""
import datetime
class AskStatus(enum.Enum):
    QUESTION: str = "QUESTION"
    ERROR: str = "ERROR"
    TOOL_CALL: str = "TOOL_CALL"
    TOOL_ERROR: str = "TOOL_ERROR" #when we call a tool but it breaks
    TOOL_CALL_RESPONSE: str = "TOOL_CALL_RESPONSE"
    RESPONSE: str = "RESPONSE"
    STREAMING_RESPONSE: str = "STREAMING_RESPONSE"
    COMPLETED: str = "COMPLETED"
    
class _ToolCallFunction(BaseModel):    
    name: str
    arguments: dict | str
    
    @model_validator(mode='before')
    @classmethod
    def _try_parse(cls,values):
        try:
            values['arguments'] = json.loads(values['arguments'])
        except:
            raise
        return values
class _ToolCall(BaseModel):
    """a canonical tool call ala openai"""
    id: str = Field(description="the unique id")
    type: str = Field('function', description="the type - usually function")
    function: _ToolCallFunction = Field(description="The function name and args")
class AskResponse(BaseModel):
    """When we ask an LLM anything we try to implement a "turn" interface as below"""
    
    message_response: typing.Optional[str] = Field(None, description="A textual response from the language model ")
    tool_calls: typing.Optional[typing.List[_ToolCall]] = Field(description="(JSONB) - The tool call payload from the language model possible in a canonical format e.g. OpenAI scheme")
    tool_call_result: typing.List[dict] = Field(description="(JSONB) data result from tool calls")
    status: AskStatus = Field(description="A turn can be in one of these states")
    session_id: str = Field(description="In Percolate a session is stored in the database against a user and question. Each response is pinned to a session", alias='session_id_out')
    

"""Graph types"""


class Node(BaseModel):
    id: int
    label: str
    metadata: typing.Dict[str, typing.Union[str, datetime.datetime]] = Field(alias="properties")


class Edge(BaseModel):
    id: int
    label: str
    start_id: int
    end_id: int
    metadata: typing.Dict[str, typing.Union[str, datetime.datetime]] = Field(alias="properties")

    @model_validator(mode='before')
    @classmethod
    def _val(cls, values):
        """remove forbidden cypher chars in case provided does not"""
        values['label'] = values['label'].replace('-','_')
        return values

class ConceptLinks(BaseModel):
    """Concept links are used in the memory system to connect users to concepts"""
    u: Node
    path: typing.List[typing.Union[Node, Edge]]
    concept: Node

    def get_link(self) -> typing.Dict[str, typing.Union[str, typing.List[typing.Dict[str, typing.Optional[str]]]]]:
        edges = [
            {
                "rel_type": p.label,
                "name": p.metadata.get("name"),
                "created_at": p.metadata.get("created_at"),
                "terminated_at": p.metadata.get("terminated_at"),
            }
            for p in self.path
            if isinstance(p, Edge)
        ]
        return {
            "user": self.u.metadata.get("name"),
            "edges": edges
        }