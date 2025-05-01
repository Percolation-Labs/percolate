"""
Going to refactor memory proxy approach and deprecate other LLM interfaces in favour of one unified one

We need to define scheme payloads for all providers for streaming (we will not implement non streaming in the first version as streaming content and buffering function calls will be the primary proxy mode)
We need a delta.to_scheme() function so any scheme can be adapted to any other

the generator will manage the stream interception: buffers function calls and aggregates usage; 
this works with the agentic multi-turn wrapper and usage as attributed to each turn
Turns eval functions and in future the eval will be key based i.e. we will not store all data retrieved which is massive but node ids for data retrieved.
When we emit we have options;
1) the output scheme
2) if usage and function calls should be emitted or blocked by the proxy (many clients wont care about those details)
"""

"""Move these class to proxy.models"""


class OpenAiRequest:
    pass

    #as anthropic request
    #as google request

class GoogleRequest:
    pass

class AnthropicRequest:
    pass

class StreamDelta:
    pass
    #to_sse_event
    #to_content


class OpenAIStreamDelta(StreamDelta):
    pass

class GoogleStreamDelta(StreamDelta):
    pass

class AnthropicStreamDelta(StreamDelta):
    pass


"""the generator is the proxy for adapting response streams to a target format while buffering function calls and usage in a canonical format"""

def stream_with_buffered_functions(response, source_scheme: str='openai', target_scheme:str='openai'):
    """
    
    """
    pass
    