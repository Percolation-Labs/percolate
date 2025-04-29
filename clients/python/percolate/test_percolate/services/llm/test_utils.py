import pytest

from percolate.services.llm.utils import HybridResponse
from percolate.services.llm import FunctionCall


class DummyResponse:
    """Simple fake response with customizable iter_lines output."""
    def __init__(self, lines):
        # lines: iterable of bytes
        self._lines = lines

    def iter_lines(self):
        for l in self._lines:
            yield l


def test_content_only_stream():
    # Simulate only text content chunks, no function calls
    lines = [
        b'data: {"choices":[{"delta":{"role":"assistant","content":"Hello"}}]}',
        b'data: {"choices":[{"delta":{"role":"assistant","content":" World"}}]}',
        b'data: [DONE]'
    ]
    resp = DummyResponse(lines)
    hr = HybridResponse(resp)
    # Collect SSE lines
    out = list(hr.iter_lines())
    # Expect two data chunks and a done event
    assert out == [
        'data: Hello\n\n',
        'data:  World\n\n',
        'event: done\n\n'
    ]
    # Content should be concatenated
    assert hr.content == 'Hello World'
    # No function calls
    assert hr.tool_calls == []



def test_to_ai_response_integration():
    # test to_ai_response creates AIResponse with correct fields
    lines = [
        b'data: {"id":"abc","model":"mymodel","choices":[{"delta":{"role":"assistant","content":"Hi"}}]}',
        b'data: {"usage":{"prompt_tokens":2,"completion_tokens":3}}',
        b'data: [DONE]'
    ]
    resp = DummyResponse(lines)
    hr = HybridResponse(resp)
    _ = list(hr.iter_lines())
    ai_resp = hr.to_ai_response(session_id='sid1')
    assert ai_resp.content == 'Hi'
    assert ai_resp.model_name == 'mymodel'
    assert ai_resp.tokens_in == 2
    assert ai_resp.tokens_out == 3
    assert ai_resp.session_id == 'sid1'
  
def test_tool_calls_basic_format_and_buffering():
    """
    Core functionality: when a 'tool_calls' delta appears, HybridResponse should
    emit an SSE event for the tool call (with emit_function_events=True), buffer it,
    and allow inspection via .tool_calls before streaming further content.
    After buffering, streaming of content and done event continues normally.
    """
    # Simulate a 'tool_calls' chunk followed by content and [DONE]
    raw_lines = [
        # Tool call chunk carries function name and args
        b'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"London","units":"C"}},"id":"1"}]}}]}',
        # Following text chunk
        b'data: {"choices":[{"delta":{"content":"Weather is sunny."}}]}',
        # Stream end
        b'data: [DONE]'
    ]
    resp = DummyResponse(raw_lines)
    hr = HybridResponse(resp)
    # First, stream SSE lines with tool events emitted
    events = list(hr.iter_lines(emit_function_events=True))
    # Expect first event to signal tool call
    assert events[0].startswith('event: function_call'), \
        f"Expected tool call event, got: {events[0]}"
    # Next, content and done events
    assert events[1] == 'data: Weather is sunny.\n\n'
    assert events[2] == 'event: done\n\n'
    # Inspect buffered tool calls: exactly one, with correct merged args
    calls = hr.tool_calls
    assert len(calls) == 1
    call = calls[0]
    assert isinstance(call, FunctionCall)
    assert call.name == 'get_weather'
    assert call.arguments == {'city': 'London', 'units': 'C'}
    assert call.id == '1'

def test_tool_calls_fragmented_arguments_merge():
    """
    Verify that fragmented 'tool_calls' deltas (name first, then argument fragments)
    are merged into a single FunctionCall with combined arguments.
    """
    # Fragments: initial with name only, then two argument fragments, then content
    raw_lines = [
        b'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"compute_sum","arguments":{}},"id":"123"}]}}]}',
        b'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"","arguments":{"a":5}},"id":""}]}}]}',
        b'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"","arguments":{"b":10}},"id":""}]}}]}',
        b'data: {"choices":[{"delta":{"content":"Sum complete."}}]}',
        b'data: [DONE]'
    ]
    class Iterator:
        def iter_lines():
            for c in raw_lines:
                yield c
                
    resp = DummyResponse(raw_lines)
    hr = HybridResponse(resp)
    # Emit all events, including intermediary tool_call fragments
    events = list(hr.iter_lines(emit_function_events=True))
    # Should have three function_call SSE events (one per fragment)
    tool_events = [e for e in events if e.startswith('event: function_call')]
    assert len(tool_events) == 3, f"Expected 3 tool_call events, got {len(tool_events)}"
    # Final content and done events present
    assert 'Sum complete.' in events[-2]
    assert events[-1] == 'event: done\n\n'
    # After buffering, .tool_calls merges fragments into one call
    calls = hr.tool_calls
    assert len(calls) == 1
    call = calls[0]
    assert call.name == 'compute_sum'
    # Arguments from both fragments should be combined
    assert call.arguments == {'a': 5, 'b': 10}
    assert call.id == '123'
    
 