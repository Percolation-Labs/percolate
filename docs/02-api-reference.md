# Percolate API Reference

## Table of Contents
1. [Overview](#overview)
2. [Authentication](#authentication)
3. [Chat Endpoints](#chat-endpoints)
4. [Agent/Entity Endpoints](#agententity-endpoints)
5. [Admin Endpoints](#admin-endpoints)
6. [Tool Management](#tool-management)
7. [Task Management](#task-management)
8. [Audio Processing](#audio-processing)
9. [File Upload (TUS)](#file-upload-tus)
10. [Integrations](#integrations)
11. [OpenAI Compatibility](#openai-compatibility)
12. [Error Handling](#error-handling)

## Overview

The Percolate API provides a comprehensive interface for building AI-powered applications. The API is RESTful, returns JSON responses, and supports both streaming and non-streaming modes.

### Base URL
```
http://localhost:5008  # Development
https://api.percolationlabs.ai  # Production
```

### Content Types
- Request: `application/json`
- Response: `application/json` or `text/event-stream` (for streaming)

## Authentication

Percolate supports multiple authentication methods:

### 1. Bearer Token + Email Header

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
     -H "X-User-Email: user@example.com" \
     https://api.percolate.ai/api/chat
```

### 2. Google OAuth

```bash
# Initiate OAuth flow
curl "https://api.percolate.ai/auth/google/login?redirect_uri=myapp://callback"
```

### 3. OAuth 2.1

The API supports full OAuth 2.1 authentication flow for MCP clients.

### Authentication Endpoints

#### GET /auth/google/login
Initiate Google OAuth flow.

**Query Parameters:**
- `redirect_uri` (optional): Where to redirect after authentication
- `sync_files` (optional): Request file sync permissions

#### GET /auth/session/info
Get current session information.

**Response:**
```json
{
  "user_id": "123e4567-e89b-12d3-a456-426614174000",
  "session_id": "sess_abc123",
  "user_info": {
    "email": "user@example.com",
    "name": "John Doe"
  }
}
```

#### GET /auth/connect
Get project connection settings (requires Bearer token).

#### OAuth 2.1 Endpoints
- `GET /auth/authorize` - Authorization endpoint
- `POST /auth/token` - Token exchange
- `POST /auth/revoke` - Token revocation
- `POST /auth/introspect` - Token introspection

## Chat Endpoints

### POST /chat/completions

Create a chat completion using the default model (OpenAI-compatible).

**Request:**
```json
{
  "messages": [
    {
      "role": "user",
      "content": "What is the capital of France?"
    }
  ],
  "model": "gpt-4",
  "stream": false
}
```

**Response:**
```json
{
  "id": "chatcmpl-123",
  "object": "chat.completion",
  "created": 1677652288,
  "model": "gpt-4",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "The capital of France is Paris."
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 8,
    "total_tokens": 18
  }
}
```

### POST /chat/

Simple ask request using Percolate agents.

**Request:**
```json
{
  "question": "What can you help me with?"
}
```

### POST /chat/agent/{agent_name}/completions

Create a completion using a specific agent.

### Provider-Specific Endpoints

- `POST /chat/anthropic/completions` - Anthropic-compatible format
- `POST /chat/google/completions` - Google-compatible format

## Agent/Entity Endpoints

### GET /entities/

List all agents.

**Response:**
```json
{
  "agents": [
    {
      "name": "pet-finder",
      "description": "Helps users find and adopt pets",
      "model": "gpt-4"
    }
  ]
}
```

### POST /entities/

Create a new agent.

**Request:**
```json
{
  "name": "my-agent",
  "description": "A helpful assistant",
  "model": "gpt-4",
  "functions": ["search", "calculate"]
}
```

### GET /entities/{agent_name}

Get a specific agent by name.

### POST /entities/search

Perform an agent-based search.

**Request:**
```json
{
  "query": "agents that can help with code",
  "limit": 10
}
```

## Admin Endpoints

### POST /admin/env/sync

Sync environment keys to database.

### POST /admin/content/upload

Upload a file to S3 storage.

**Request:** Multipart form data
```
POST /admin/content/upload
Content-Type: multipart/form-data

file: (binary)
```

### GET /admin/content/files

List files stored in S3.

### POST /admin/schedules

Create a new scheduled task.

**Request:**
```json
{
  "name": "daily_report",
  "schedule": "0 9 * * *",
  "spec": {
    "task": "generate_report"
  }
}
```

### POST /admin/index/

Index entity and get audit log id.

**Request:**
```json
{
  "content": "Content to index",
  "metadata": {
    "source": "api"
  }
}
```

## Tool Management

### GET /tools/

List available tools.

**Response:**
```json
{
  "tools": [
    {
      "name": "search",
      "description": "Search the knowledge base"
    }
  ]
}
```

### POST /tools/eval

Evaluate a function call.

**Request:**
```json
{
  "function_name": "search",
  "arguments": {
    "query": "machine learning"
  }
}
```

### POST /tools/search

Semantic search for tools.

## Task Management

### GET /tasks/

Get tasks.

### POST /tasks/

Create a task.

**Request:**
```json
{
  "name": "Research AI trends",
  "description": "Analyze current AI technology trends"
}
```

### POST /tasks/research

Create a research plan.

**Request:**
```json
{
  "topic": "Machine Learning in Healthcare",
  "depth": "comprehensive"
}
```

### POST /tasks/research/execute

Execute a research plan.

## Audio Processing

### POST /audio/upload

Upload an audio file for processing.

**Request:** Multipart form data

### GET /audio/transcription/{file_id}

Get the transcription of an audio file.

**Response:**
```json
{
  "transcription": "Hello, this is the transcribed text.",
  "chunks": [
    {
      "start": 0.0,
      "end": 2.5,
      "text": "Hello, this is"
    }
  ]
}
```

### GET /audio/status/{file_id}

Get processing status of an audio file.

## File Upload (TUS)

Percolate implements the TUS resumable upload protocol.

### POST /tus/

Create a new upload.

**Headers:**
```
Upload-Length: 1048576
Upload-Metadata: filename d29ybGRfZG9taW5hdGlvbl9wbGFuLnBkZg==
```

**Response:**
```
Location: https://api.percolate.ai/tus/abc123
```

### PATCH /tus/{upload_id}

Upload a chunk.

**Headers:**
```
Upload-Offset: 0
Content-Type: application/offset+octet-stream
```

### GET /tus/search/semantic

Semantic search for files.

**Query Parameters:**
- `query`: Search query
- `limit`: Number of results

## Integrations

### POST /x/web/search

Perform web search.

**Request:**
```json
{
  "query": "latest AI news",
  "max_results": 10
}
```

### POST /x/web/fetch

Fetch web resource and optionally convert to markdown.

**Request:**
```json
{
  "url": "https://example.com/article",
  "to_markdown": true
}
```

### POST /x/mail/fetch

Fetch emails for any domain.

**Request:**
```json
{
  "limit": 50,
  "query": "is:unread"
}
```

### POST /x/calendar/fetch

Fetch calendar events.

## OpenAI Compatibility

Percolate provides OpenAI-compatible endpoints for easy integration.

### GET /v1/models

List available models.

**Response:**
```json
{
  "object": "list",
  "data": [
    {
      "id": "gpt-4",
      "object": "model",
      "created": 1677652288,
      "owned_by": "openai"
    }
  ]
}
```

### POST /v1/chat/completions

Same as `/chat/completions` but at OpenAI-compatible path.

## Error Handling

All errors follow a consistent format:

```json
{
  "error": {
    "type": "invalid_request_error",
    "message": "Invalid API key provided",
    "code": "invalid_api_key",
    "status": 401
  }
}
```

### Error Types

| Type | Description | Status Code |
|------|-------------|-------------|
| invalid_request_error | Invalid request parameters | 400 |
| authentication_error | Authentication failed | 401 |
| permission_error | Insufficient permissions | 403 |
| not_found_error | Resource not found | 404 |
| server_error | Internal server error | 500 |

## SDK Usage

### Python
```python
import percolate as p8

# Basic chat
response = p8.chat("What is the meaning of life?")

# Use specific agent
agent = p8.Agent(MyCustomAgent)
result = agent.run("Help me with this task")
```

## Best Practices

1. **Use Bearer token with X-User-Email** for API authentication
2. **Implement exponential backoff** for retries
3. **Handle streaming responses** properly using SSE
4. **Use TUS protocol** for large file uploads
5. **Check agent availability** before using specific agents