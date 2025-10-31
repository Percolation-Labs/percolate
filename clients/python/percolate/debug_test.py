#!/usr/bin/env python3
import percolate as p8
from percolate.services.llm.CallingContext import CallingContext  
from percolate.models.p8.types import UserRoleAgent

agent = p8.Agent(UserRoleAgent)
context = CallingContext(user_id='10e0a97d-a064-553a-9043-3c1f0a6e6725', role_level=10)

print("🔥 CLIENT: Creating stream...")
stream = agent.stream("What can you tell me about create one", context=context)
print(f"🔥 CLIENT: Got stream: {type(stream)}")

print("🔥 CLIENT: Calling iter_lines()...")
iterator = stream.iter_lines()
print(f"🔥 CLIENT: Got iterator: {type(iterator)}")

print("🔥 CLIENT: Starting iteration...")
count = 0
for s in iterator:
    count += 1
    print(f"🔥 CLIENT: Line #{count}: {len(s)} bytes")
    if count >= 10:  # Get more lines to see the streaming
        break
        
print(f"🔥 CLIENT: Completed with {count} lines")