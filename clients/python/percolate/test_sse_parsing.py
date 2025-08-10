#!/usr/bin/env python3
"""
Test SSE parsing logic to ensure it handles both data: and event: formats correctly
"""

from percolate.services.llm.utils.stream_utils import LLMStreamIterator

def test_sse_parsing():
    # Create a mock iterator to test the parsing logic
    iterator = LLMStreamIterator(lambda: [], scheme="openai")
    
    # Test cases for different SSE line formats
    test_cases = [
        # Standard OpenAI streaming format
        ('data: {"id": "chatcmpl-123", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": "Hello"}}]}', True),
        
        # Function call event format
        ('event: function_call', None),
        ('data: {"name": "get_weather", "arguments": "{\\"location\\": \\"NYC\\"}"}', True),
        
        # End marker
        ('data: [DONE]', None),
        
        # Empty line
        ('', None),
        
        # Invalid JSON in data line
        ('data: {invalid json}', None),
    ]
    
    print("🧪 Testing SSE parsing logic...")
    
    for line, should_have_data in test_cases:
        result = iterator._extract_json_from_sse_line(line)
        
        if should_have_data is True:
            if result is not None:
                print(f"✅ PASS: '{line[:50]}...' -> Got JSON data")
            else:
                print(f"❌ FAIL: '{line[:50]}...' -> Expected JSON data but got None")
        elif should_have_data is None:
            if result is None:
                print(f"✅ PASS: '{line[:30]}...' -> Correctly returned None")
            else:
                print(f"❌ FAIL: '{line[:30]}...' -> Expected None but got data")
    
    print("\n🎯 All SSE parsing tests completed!")

if __name__ == "__main__":
    test_sse_parsing()