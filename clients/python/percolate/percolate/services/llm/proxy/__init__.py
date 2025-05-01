"""
To refactor memory proxy approach and deprecate other LLM interfaces in favour of one unified one

We need to define scheme payloads for all providers for streaming (we will not implement non streaming in the first version as streaming content and buffering function calls will be the primary proxy mode)
We need a delta.to_scheme() function so any scheme can be adapted to any other

the generator will manage the stream interception: buffers function calls and aggregates usage; 
this works with the agentic multi-turn wrapper and usage as attributed to each turn
Turns eval functions and in future the eval will be key based i.e. we will not store all data retrieved which is massive but node ids for data retrieved.
When we emit we have options;
1) the output scheme
2) if usage and function calls should be emitted or blocked by the proxy (many clients wont care about those details)


UNIT TESTS

-- all payload structures and converters are unit tested with sample payload structures
-- converters verify that we can adapt between formats

"""

"""move these classes to proxy.utils"""

class BackgroundAudit:
    """the background audit sends the AIResponse audit records on a background thread to non block the user stream
    p8.Repository(AIResponse).update_records(ai_response)
    This is used by higher level classes that use the underlying streamers and constructor their own AIResponse turn which consists of both a tool call from the LLM and the local eval data
    This auditor is provided to make streaming efficient while also supporting full audit in the memory proxy
    """
    pass

"""Move these class to proxy.models"""


class LLMApiRequest:
    """a base class to provide interface methods for general LLM API requests"""
    pass
class OpenAiRequest(LLMApiRequest):
    """The Open AI API contract for chat completions with tool calls (functions not supported)"""
    pass

    #as anthropic request
    #as google request

class GoogleRequest(LLMApiRequest):
    """Google completions API contract"""
    pass

class AnthropicRequest(LLMApiRequest):
    """Anthropic completions API contract"""
    pass

class StreamDelta:
    """an abstract base class for any streaming payload with some helper methods"""
    pass
    #to_sse_event
    #to_content
    #parse_sse


class OpenAIStreamDelta(StreamDelta):
    """SSe event payload i.e. for the underlying data json structured data in the sse event"""
    pass

class GoogleStreamDelta(StreamDelta):
    """SSe event payload i.e. for the underlying data json structured data in the sse event"""
    pass

    #to_open_ai_scheme
class AnthropicStreamDelta(StreamDelta):
    """SSe event payload i.e. for the underlying data json structured data in the sse event"""
    pass

    #to_open_ai_scheme


"""
move these classes to proxy.stream_generators
the generator is the proxy for adapting response streams to a target format while buffering function calls and usage in a canonical format"""


def stream_with_buffered_functions(response, source_scheme: str='openai', target_scheme:str='openai', relay_tool_use_events:bool=False, relay_usage_events:bool=False):
    """
    This function relays raw events while buffering functions and emitting aggregated usage in the end IF the target scheme is open ai. Internally we use openai as canonical stream but users may want to see other formats.
    
    The stream buffer must take a HTTP response stream (from calling an LLM completions API) which can come from any source scheme i.e. anthropic sse events, google sse events or openai sse events
    - depending on the target scheme we can adapt the sse lines into a target format using the StreamDelta.to_[scheme] implementation
    - we construct tool calls internally in the openai scheme for our own use and we only relay tool-call or usage messages in the target scheme if the flag is set because such details are often hidden from a general user.
    - usage appears only on the final event for openai; this means for other schemes we need to aggregate it for own internal consistent use and yield it in the generator as if its an openai final message (agentic loops use usage as a terminating state)
    - the internal json "chunks" are adapted to the canonical openai scheme while the raw line is relayed in whatever the target_scheme is;
      this allows users to decide how to consume raw events but openai is the default 
    
    *generator yields [raw_line_in_target_scheme], [chunk_in_open_ai_scheme])*
    """
    
    pass
    
def request_stream_from_model(request: LLMApiRequest, context, target_scheme:str='openai', **kwargs):
    """
    make the request to the given API and then stream results with 'stream_with_buffered_functions'
    - choose the garget scheme for the sse events that are emitted, pass kwargs to control the stream output options
    """

    #
    
    """1. background auditor.audit_user_session(context.session_id, .... )"""
    
    """2. make LLM request"""
    
    """3. return response wrapped into the stream with buffered functions"""

    pass


def flush_ai_response_audit(content, tool_calls, tool_responses, usage):
    """
    provide this helper so that we can construct the ai response and flush on a background thread.
    these are turns with request-response
    """
    
    pass