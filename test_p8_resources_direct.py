#!/usr/bin/env python3
"""Direct test of p8-Resources agent using the API"""

import asyncio
import os
import httpx
import json

async def test_p8_resources_agent():
    """Test p8-Resources agent directly via API"""
    
    # Try local server first
    api_url = "http://localhost:5008"
    api_key = "postgres"  # Local test key
    
    if not api_key:
        print("❌ Error: P8_API_KEY environment variable not set")
        return
    
    print("🧪 Testing p8-Resources Agent Directly")
    print("=" * 60)
    print(f"📌 API URL: {api_url}")
    print(f"🔑 API Key: {api_key[:10]}...")
    print(f"🤖 Agent: p8-Resources")
    print()
    
    # Test queries
    test_queries = [
        "What kind of resources do you have access to?",
        "List some of the data or documents you can access",
        "Tell me about the Percolate platform"
    ]
    
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    
    async with httpx.AsyncClient() as client:
        for i, query in enumerate(test_queries, 1):
            print(f"\n{'='*60}")
            print(f"🧪 Test {i}: {query}")
            print(f"{'='*60}\n")
            
            # Prepare the chat completions request
            payload = {
                "model": "gpt-4o-mini",  # Default model
                "messages": [
                    {"role": "user", "content": query}
                ],
                "stream": False  # Non-streaming for simplicity
            }
            
            endpoint = f"{api_url}/chat/agent/p8-Resources/completions"
            
            try:
                print(f"⏳ Sending request to: {endpoint}")
                response = await client.post(
                    endpoint,
                    json=payload,
                    headers=headers,
                    timeout=30.0
                )
                
                print(f"📡 Status: {response.status_code}")
                
                if response.status_code == 200:
                    data = response.json()
                    print("✅ Success!")
                    
                    # Extract the assistant's response
                    if "choices" in data and len(data["choices"]) > 0:
                        content = data["choices"][0]["message"]["content"]
                        print("\n📝 Response:")
                        print("-" * 40)
                        print(content)
                        print("-" * 40)
                    else:
                        print("❓ Unexpected response format:")
                        print(json.dumps(data, indent=2))
                else:
                    print(f"❌ Error: {response.status_code}")
                    print(f"Response: {response.text}")
                    
            except Exception as e:
                print(f"❌ Exception: {e}")
                import traceback
                traceback.print_exc()
            
            # Small delay between requests
            if i < len(test_queries):
                await asyncio.sleep(2)
    
    print("\n✅ All tests completed!")

if __name__ == "__main__":
    asyncio.run(test_p8_resources_agent())