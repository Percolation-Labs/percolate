import typing
from pydantic import BaseModel, Field
from percolate.utils.env import DEFAULT_MODEL
from percolate.utils import logger
import uuid

DEFAULT_MAX_AGENT_LOOPS = 5
DEFAULT_MODEL_TEMPERATURE = 0.0


def get_user_memory(user_id, thread_id:str=None, **kwargs):
    """
    lookup a user state by user_id but support looking up by email which is effectively and id in percolate
    """
   
    try: 
        from percolate.models import User
        import percolate as p8
         
        query_id_or_email = f"""  SELECT * FROM  p8."User" WHERE id::TEXT = %s or email = %s """
        
        user = p8.repository(User).execute(query_id_or_email, data=(user_id,user_id))
        
        if user:
            user = User(**user[0])
            return user.as_memory(**kwargs)
    except:
        logger.warning(f"Failed to get memory for user {user_id}")
        raise

class ApiCallingContext(BaseModel):
    """calling context object - all have defaults
    an agent session uses these things to control how to communicate with the user or the LLM Api
    """

    session_id: typing.Optional[str] = Field(
        default=None, description="A goal orientated session id actually maps to thread_id in the database and not session.id"
    )
    
    chat_id: typing.Optional[str] = Field(
        default=None, description="The chat_id from OpenWebUI, if provided - usually used as session_id"
    )

    session_context: typing.Optional[str] = Field(
        default=None,
        description="For routing purposes, describe the session's objective",
    )

    prefer_json: typing.Optional[bool] = Field(
        default=False, description="If the json format is preferred in response"
    )
    response_model: typing.Optional[str] = Field(
        default=None, description="A Pydantic format model to use to respond"
    )
    username: typing.Optional[str] = Field(
        default=None, description="The session username"
    )
    user_id: typing.Optional[str|uuid.UUID] = Field(
        default=None, description="UUID user id is more accurate if known but we try to resolve"
    )
    channel_context: typing.Optional[str] = Field(
        default=None,
        description="A channel id e.g. slack channel but more broadly any grouping",
    )
    channel_ts: typing.Optional[str] = Field(
        default=None, description="A channel conversation id e.g. slack timestamp (ts)"
    )

    prefers_streaming: typing.Optional[bool] = Field(
        default=False,
        description="Indicate if a streaming response is preferred with or without a callback",
    )
    
    is_hybrid_streaming: typing.Optional[bool] = Field(
        default=False,
        description="Hybrid Streaming calls functions internally but streams text content",
    )
      
    temperature: typing.Optional[float] = Field(
        default=DEFAULT_MODEL_TEMPERATURE, description="The LLM temperature"
    )
    plan: typing.Optional[str] = Field(
        default=None,
        description="A specific plan/prompt to override default agent plan",
    )
    max_iterations: typing.Optional[int] = Field(
        default=DEFAULT_MAX_AGENT_LOOPS,
        description="Agents iterated in a loop to call functions. Set the max number of iterations",
    )
    model: typing.Optional[str] = Field(
        default=DEFAULT_MODEL, description="The LLM Model to use"
    )

    file_uris: typing.Optional[typing.List[str]] = Field(
        description="files associated with the context", default_factory=list
    )

    def get_response_format(cls):
        """"""
        if cls.prefer_json:
            return {"type": "json_object"}


class CallingContext(ApiCallingContext):
    """add the non serializable callbacks"""

    streaming_callback: typing.Optional[typing.Callable] = Field(
        default=None,
        description="A callback to stream partial results e.g. print progress",
    )
    response_callback: typing.Optional[typing.Callable] = Field(
        default=None,
        description="A callback to send final response e.g a Slack Say method",
    )
    
    def get_user_memory(self):
        """
        given a user context we can lookup the users recents
        """
        if self.username:
            return get_user_memory(self.username,self.channel_ts)

    @staticmethod
    def simple_printer(d):
        print(d,end='')
    
    def in_streaming_mode(cls, is_hybrid_streaming:bool=True, model:str=None):
        """convert context as is to streaming"""
        data = cls.model_dump()
        data['prefers_streaming'] = True
        data['is_hybrid_streaming'] = is_hybrid_streaming
        if model:
            data['model'] = model
        return CallingContext(**data)

    @property
    def is_streaming(cls):
        """the streaming mode is either of these cases"""
        return cls.prefers_streaming or cls.streaming_callback is not None

    @classmethod
    def with_model(cls, model_name:str):
        """
        construct the default model context but with different model
        """
        
        defaults = CallingContext().model_dump()
        if model_name:
            defaults['model'] = model_name
        return CallingContext(**defaults)
    
