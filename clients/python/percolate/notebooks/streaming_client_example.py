"""
A simple example client to demonstrate proper streaming consumption
"""

import requests
import json
import time

# API URL - adjust as needed
API_URL = "http://localhost:8000/chat/completions"

def consume_stream_properly():
    """Example of how to properly consume a streaming response"""
    
    # Request payload
    payload = {
        "model": "gpt-4o-mini",  # Change to match your available model
        "prompt": "Write a short poem about Paris",
        "max_tokens": 100,
        "temperature": 0.7,
        "stream": True  # Enable streaming
    }
    
    # Make request with streaming enabled
    print("Sending request...")
    response = requests.post(
        API_URL,
        json=payload,
        headers={"Content-Type": "application/json"},
        stream=True  # This is critical for streaming
    )
    
    if response.status_code != 200:
        print(f"Error: {response.status_code}")
        print(response.text)
        return
    
    print("\nReceiving streaming response...")
    print("-" * 50)
    
    # Process each line in the stream
    accumulated_text = ""
    
    for line in response.iter_lines():
        if line:
            line_text = line.decode('utf-8')
            
            # Handle SSE format (data: prefix)
            if line_text.startswith('data: '):
                # Remove SSE prefix
                line_text = line_text[6:]
                
                # Skip [DONE] marker
                if line_text == "[DONE]":
                    continue
                
                try:
                    # Parse the JSON data
                    data = json.loads(line_text)
                    
                    # Extract content from the canonical format
                    text = ""
                    if "choices" in data and data["choices"]:
                        choice = data["choices"][0]
                        # Check for content in the canonical format
                        text = choice.get("text", "")
                        
                        # Also check for tool calls
                        if "tool_call" in choice and choice["tool_call"]:
                            tool = choice["tool_call"]
                            print(f"\n\nTool Call: {tool.get('name', '')}")
                            print(f"Arguments: {tool.get('arguments', '')}")
                    
                    # Display the content character by character
                    if text:
                        accumulated_text += text
                        # Print character by character with small delay
                        for char in text:
                            print(char, end="", flush=True)
                            time.sleep(0.01)  # Small delay to demonstrate character-by-character display
                
                except json.JSONDecodeError:
                    # If the line isn't valid JSON, just print it
                    print(f"Raw data: {line_text}")
    
    print("\n" + "-" * 50)
    print(f"Complete text: {accumulated_text}")

def consume_stream_with_tool_calls():
    """Example of consuming a streaming response with tool calls"""
    
    # Request payload with a tool
    payload = {
        "model": "gpt-4o-mini",  # Change to match your available model
        "prompt": "What's the weather like in Paris today?",
        "max_tokens": 100,
        "temperature": 0.7,
        "stream": True,  # Enable streaming
        "tools": [
            {
                "type": "function",
                "function": {
                    "name": "get_weather",
                    "description": "Get the current weather in a given location",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "location": {
                                "type": "string",
                                "description": "The city and state, e.g. San Francisco, CA"
                            },
                            "date": {
                                "type": "string",
                                "description": "The date for the weather forecast (YYYY-MM-DD)"
                            }
                        },
                        "required": ["location"]
                    }
                }
            }
        ]
    }
    
    # Make request with streaming enabled
    print("Sending request with tool...")
    response = requests.post(
        API_URL,
        json=payload,
        headers={"Content-Type": "application/json"},
        stream=True
    )
    
    if response.status_code != 200:
        print(f"Error: {response.status_code}")
        print(response.text)
        return
    
    print("\nReceiving streaming response with possible tool calls...")
    print("-" * 50)
    
    # Track accumulated content and tool calls
    accumulated_text = ""
    tool_calls = []
    current_tool_call = None
    
    for line in response.iter_lines():
        if line:
            line_text = line.decode('utf-8')
            
            # Handle SSE format
            if line_text.startswith('data: '):
                line_text = line_text[6:]
                
                if line_text == "[DONE]":
                    continue
                
                try:
                    data = json.loads(line_text)
                    
                    if "choices" in data and data["choices"]:
                        choice = data["choices"][0]
                        
                        # Handle text content
                        if "text" in choice and choice["text"]:
                            text = choice["text"]
                            accumulated_text += text
                            # Display incrementally
                            for char in text:
                                print(char, end="", flush=True)
                                time.sleep(0.01)
                        
                        # Handle tool calls
                        if "tool_call" in choice and choice["tool_call"]:
                            tool = choice["tool_call"]
                            
                            # Check if this is a new tool call or continuation
                            if current_tool_call is None or current_tool_call.get("id") != tool.get("id"):
                                # Start a new tool call
                                current_tool_call = {
                                    "id": tool.get("id", ""),
                                    "name": tool.get("name", ""),
                                    "arguments": tool.get("arguments", "")
                                }
                                tool_calls.append(current_tool_call)
                                print(f"\n\nTool Call: {current_tool_call['name']}")
                            else:
                                # Continue existing tool call (e.g., append to arguments)
                                current_tool_call["arguments"] += tool.get("arguments", "")
                            
                            # Display current arguments
                            print(f"\rArguments: {current_tool_call['arguments']}", end="")
                        
                        # Check for finish reason
                        if choice.get("finish_reason"):
                            print(f"\nFinish reason: {choice['finish_reason']}")
                
                except json.JSONDecodeError:
                    print(f"\nRaw data: {line_text}")
    
    print("\n" + "-" * 50)
    
    # Final summary
    print(f"Complete text: {accumulated_text}")
    
    if tool_calls:
        print("\nTool Calls:")
        for i, tool in enumerate(tool_calls):
            print(f"  {i+1}. {tool['name']}: {tool['arguments']}")

if __name__ == "__main__":
    # Choose which example to run
    print("1. Basic streaming example")
    print("2. Streaming with tool calls example")
    choice = input("Enter example number to run (1 or 2): ")
    
    if choice == "2":
        consume_stream_with_tool_calls()
    else:
        consume_stream_properly()