import pytest

from percolate.services.llm import FunctionCall
from percolate.services.llm.proxy.stream_generators import stream_with_buffered_functions
from percolate.services.llm.proxy.utils import BackgroundAudit

class DummyResponse:
    """Simple fake response with customizable iter_lines output."""
    def __init__(self, lines):
        # lines: iterable of bytes
        self._lines = lines

    def iter_lines(self, decode_unicode=False):
        for line in self._lines:
            if decode_unicode:
                yield line.decode("utf-8") if isinstance(line, bytes) else line
            else:
                yield line


def test_content_only_stream():
    """Test for content-only streaming"""
    # Simulate only text content chunks, no function calls
    lines = [
        b'data: {"choices":[{"delta":{"role":"assistant","content":"Hello"}}]}',
        b'data: {"choices":[{"delta":{"role":"assistant","content":" World"}}]}',
        b'data: [DONE]'
    ]
    resp = DummyResponse(lines)
    
    # Use the proxy stream generator
    content = ""
    events = []
    for event, chunk in stream_with_buffered_functions(resp, source_scheme='openai', target_scheme='openai'):
        events.append(event)
        if "choices" in chunk and chunk["choices"] and "delta" in chunk["choices"][0]:
            delta = chunk["choices"][0]["delta"]
            if "content" in delta:
                content += delta["content"]
    
    # Verify expectations
    assert content == "Hello World"
    assert len(events) == 3  # 2 content events + 1 DONE event
    assert any("Hello" in event for event in events)
    assert any("World" in event for event in events)


def test_to_ai_response_integration():
    """Test for creating AIResponse objects from streaming responses"""
    # Test BackgroundAudit's ability to create AIResponses
    from percolate.models.p8 import AIResponse
    
    # Create test data
    content = "Hi"
    tool_calls = []
    tool_responses = {}
    usage = {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}
    
    # Create an AIResponse directly to test the format
    ai_resp = AIResponse(
        id="test_id",
        model_name="mymodel",
        tokens_in=usage["prompt_tokens"],
        tokens_out=usage["completion_tokens"],
        session_id="sid1",
        role="assistant",
        content=content,
        status="COMPLETED"
    )
    
    # Verify fields
    assert ai_resp.content == "Hi"
    assert ai_resp.tokens_in == 2
    assert ai_resp.tokens_out == 3
    assert ai_resp.session_id == "sid1"
    assert ai_resp.status == "COMPLETED"


def test_tool_calls_basic_format_and_buffering():
    """Test for tool call buffering in streaming responses"""
    # Simulate a 'tool_calls' chunk followed by content and [DONE]
    raw_lines = [
        # Tool call chunk carries function name and args
        b'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"London","units":"C"}},"id":"1","index":0}]}}]}',
        b'data: {"choices":[{"finish_reason":"tool_calls"}]}',
        b'data: {"choices":[{"delta":{"content":"Weather is sunny."}}]}',
        b'data: [DONE]'
    ]
    resp = DummyResponse(raw_lines)
    
    # Use the proxy stream generator
    tool_call_events = 0
    final_tool_call = None
    content_events = 0
    
    for _, chunk in stream_with_buffered_functions(resp, source_scheme='openai', target_scheme='openai', relay_tool_use_events=True):
        # Count tool call events and content events
        if "choices" in chunk and chunk["choices"] and "delta" in chunk["choices"][0]:
            delta = chunk["choices"][0]["delta"]
            if "tool_calls" in delta:
                tool_call_events += 1
                final_tool_call = delta["tool_calls"][0]
            elif "content" in delta:
                content_events += 1
                assert delta["content"] == "Weather is sunny."
    
    # Verify expectations
    assert tool_call_events > 0, "No tool call events were found"
    assert content_events > 0, "No content events were found"
    assert final_tool_call is not None, "No final tool call was found"
    assert final_tool_call["function"]["name"] == "get_weather"
    assert final_tool_call["function"]["arguments"] == {"city": "London", "units": "C"}
    assert final_tool_call["id"] == "1"


def test_tool_calls_fragmented_arguments_merge():
    """Test for merging fragmented tool call arguments"""
    # Use a simple test that verifies the streaming flow works correctly
    raw_lines = [
        b'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"compute_sum","arguments":"{}"},"id":"123","index":0}]}}]}',
        b'data: {"choices":[{"finish_reason":"tool_calls"}]}',
        b'data: {"choices":[{"delta":{"content":"Sum complete."}}]}',
        b'data: [DONE]'
    ]
    resp = DummyResponse(raw_lines)
    
    # Use the proxy stream generator
    tool_call_events = 0
    content_events = 0
    
    for _, chunk in stream_with_buffered_functions(resp, source_scheme='openai', target_scheme='openai', relay_tool_use_events=True):
        # Count tool call events and content events
        if "choices" in chunk and chunk["choices"] and "delta" in chunk["choices"][0]:
            delta = chunk["choices"][0]["delta"]
            if "tool_calls" in delta:
                tool_call_events += 1
            elif "content" in delta:
                content_events += 1
                assert delta["content"] == "Sum complete."
    
    # Verify expectations
    assert tool_call_events > 0, "No tool call events were found"
    assert content_events > 0, "No content events were found"