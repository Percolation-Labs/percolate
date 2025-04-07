"""
Example of how to properly consume streaming responses from the Percolate API.

This script demonstrates the correct way to handle streaming responses,
showing incremental updates rather than waiting for complete chunks.
"""

import requests
import json
import time

# API URL - adjust as needed for your environment
API_URL = "http://localhost:8000/chat/completions"

def stream_example():
    """Simple example of consuming a streaming response with proper incremental display."""
    
    # Request payload
    payload = {
        "model": "gpt-4o-mini",  # Change to match your available model
        "prompt": "Write a poem about Paris in 4 lines",
        "max_tokens": 100,
        "temperature": 0.7,
        "stream": True
    }
    
    # Make the request with streaming enabled
    print("Sending request...")
    response = requests.post(
        API_URL,
        json=payload,
        headers={"Content-Type": "application/json"},
        stream=True  # This is critical for streaming!
    )
    
    if response.status_code != 200:
        print(f"Error: {response.status_code}")
        print(response.text)
        return
    
    print("\nStreaming response (character by character):")
    print("-" * 50)
    
    # Accumulated text for final output
    full_text = ""
    
    # Process each line in the stream
    for line in response.iter_lines():
        if line:
            try:
                # Decode the line from bytes to string
                line_text = line.decode('utf-8')
                
                # Handle SSE format if it starts with 'data: '
                if line_text.startswith('data: '):
                    line_text = line_text[6:]  # Remove 'data: ' prefix
                
                # Skip the [DONE] marker
                if line_text == "[DONE]":
                    continue
                
                # Parse the JSON
                data = json.loads(line_text)
                
                # Extract content based on the response format
                content = ""
                if "choices" in data and data["choices"]:
                    # Standard OpenAI format
                    if "delta" in data["choices"][0]:
                        delta = data["choices"][0]["delta"]
                        if "content" in delta:
                            content = delta["content"]
                    # Our canonical format
                    elif "text" in data["choices"][0]:
                        content = data["choices"][0]["text"]
                
                # Print each character with a small delay to demonstrate incremental streaming
                if content:
                    full_text += content
                    for char in content:
                        print(char, end='', flush=True)
                        time.sleep(0.01)  # Slow down to show incremental display
            
            except json.JSONDecodeError:
                # Handle non-JSON data if any
                print(f"Raw: {line.decode('utf-8')}")
    
    print("\n" + "-" * 50)
    print(f"Complete text: {full_text}")

if __name__ == "__main__":
    stream_example()