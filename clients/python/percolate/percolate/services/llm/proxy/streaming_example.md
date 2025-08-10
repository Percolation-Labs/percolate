# Streaming Behavior Example

## Anthropic Input: Multiple Content Deltas + Tool Call

```
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I'll"}}
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" get"}}  
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" the weather"}}

data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"get_weather","input":{}}}
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"Paris\"}"}}
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
```

## OpenAI Output: Content Streams, Tool Calls Buffer

### Content Event 1 - IMMEDIATE
```json
{
  "choices": [{
    "delta": {"content": "I'll"},
    "finish_reason": null
  }]
}
```

### Content Event 2 - IMMEDIATE  
```json
{
  "choices": [{
    "delta": {"content": " get"},
    "finish_reason": null
  }]
}
```

### Content Event 3 - IMMEDIATE
```json
{
  "choices": [{
    "delta": {"content": " the weather"},
    "finish_reason": null
  }]
}
```

### Tool Call Event - BUFFERED (Complete)
```json
{
  "choices": [{
    "delta": {
      "tool_calls": [{
        "id": "toolu_123",
        "type": "function", 
        "function": {
          "name": "get_weather",
          "arguments": "{\"location\": \"Paris\"}"
        }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

## Key Differences

| Aspect | Content | Tool Calls |
|--------|---------|------------|
| **Streaming** | ✅ Immediate (each delta) | ❌ Buffered (complete only) |
| **Aggregation** | ❌ No aggregation | ✅ Arguments accumulated |
| **User Experience** | 📝 Text appears as typed | 🔧 Function called when ready |
| **Use Case** | Real-time text display | Complete function execution |

This ensures:
- **Real-time user experience**: Text appears immediately as it's generated
- **Complete function calls**: Tools receive complete, valid JSON arguments
- **No partial function calls**: Prevents broken JSON from being executed