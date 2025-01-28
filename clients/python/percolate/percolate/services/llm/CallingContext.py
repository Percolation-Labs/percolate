import typing
from pydantic import BaseModel, Field
from percolate.utils.env import DEFAULT_MODEL

DEFAULT_MAX_AGENT_LOOPS = 5
DEFAULT_MODEL_TEMPERATURE = 0.0


class ApiCallingContext(BaseModel):
    """calling context object - all have defaults
    an agent session uses these things to control how to communicate with the user or the LLM Api
    """

    session_id: typing.Optional[str] = Field(
        default=None, description="A goal orientated session id"
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