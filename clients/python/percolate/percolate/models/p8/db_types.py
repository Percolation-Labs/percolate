"""keep track of the schema used to return database objects
this will evolve and change plenty in the beginning
"""
from pydantic import BaseModel, Field
import typing
import enum
"""1 responses from agent calls"""

class AskStatus(enum.Enum):
    QUESTION: str = "QUESTION"
    ERROR: str = "ERROR"
    TOOL_CALL: str = "TOOL_CALL"
    TOOL_CALL_RESPONSE: str = "TOOL_CALL_RESPONSE"
    RESPONSE: str = "RESPONSE"
    STREAMING_RESPONSE: str = "STREAMING_RESPONSE"
    COMPLETED: str = "COMPLETED"
    
class AskResponse(BaseModel):
    """When we ask an LLM anything we try to implement a "turn" interface as below"""
    
    message_response: str = Field(description="A textual response from the language model ")
    tool_calls: typing.Optional[typing.List[dict]] = Field(description="(JSONB) - The tool call payload from the language model possible in a canonical format e.g. OpenAI scheme")
    tool_call_result: typing.List[dict] = Field(description="(JSONB) data result from tool calls")
    status: AskStatus = Field(description="A turn can be in one of these states")
    session_id: str = Field(description="In Percolate a session is stored in the database against a user and question. Each response is pinned to a session")
    

