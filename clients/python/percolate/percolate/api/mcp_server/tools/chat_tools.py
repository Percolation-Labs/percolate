"""Chat tools for MCP - streaming agent interactions"""

from typing import Optional, Dict, Any, List, AsyncIterator, Union
from pydantic import BaseModel, Field
from fastmcp import FastMCP
from ..base_repository import BaseMCPRepository
import json
from percolate.utils import logger


class AskOneParams(BaseModel):
    """Parameters for ask_one tool"""
    query: str = Field(
        ...,
        description="The question or prompt to send to the agent"
    )
    agent: Optional[str] = Field(
        None,
        description="The agent to use (defaults to P8_DEFAULT_AGENT or 'p8.Resources')"
    )
    model: Optional[str] = Field(
        None,
        description="The LLM model to use (defaults to P8_DEFAULT_MODEL or 'gpt-4o-mini')"
    )
    session_id: Optional[str] = Field(
        None,
        description="Optional session ID for conversation continuity"
    )
    stream: bool = Field(
        True,
        description="Whether to stream the response (default: true)"
    )


def parse_sse_line(line: str) -> Optional[Dict[str, Any]]:
    """Parse a Server-Sent Event line into event and data"""
    if not line or line.startswith(':'):
        return None
    
    if line.startswith('event:'):
        return {'type': 'event', 'value': line[6:].strip()}
    elif line.startswith('data:'):
        data_str = line[5:].strip()
        if data_str == '[DONE]':
            return {'type': 'done'}
        try:
            return {'type': 'data', 'value': json.loads(data_str)}
        except json.JSONDecodeError:
            # Some data might not be JSON
            return {'type': 'data', 'value': data_str}
    elif line.startswith('id:'):
        return {'type': 'id', 'value': line[3:].strip()}
    elif line.startswith('retry:'):
        return {'type': 'retry', 'value': int(line[6:].strip())}
    
    return None


async def format_streamed_response(stream: Union[str, AsyncIterator[str]]) -> str:
    """Format the streamed response for display"""
    markdown_parts = []
    events = []
    current_content = []
    metadata = {}
    
    # Handle non-streaming response
    if isinstance(stream, str):
        return f"## 💬 Response\n{stream}"
    
    # Handle streaming response
    async for line in stream:
        parsed = parse_sse_line(line)
        if not parsed:
            continue
            
        if parsed['type'] == 'event':
            event_name = parsed['value']
            events.append(f"🔸 {event_name}")
            logger.debug(f"SSE Event: {event_name}")
            
        elif parsed['type'] == 'data':
            data = parsed['value']
            if isinstance(data, dict):
                # Handle different data types
                if 'content' in data:
                    # Chat completion chunk
                    current_content.append(data['content'])
                elif 'function' in data:
                    # Function call event
                    func_name = data['function'].get('name', 'unknown')
                    events.append(f"🔧 Function: {func_name}")
                    if 'arguments' in data['function']:
                        events.append(f"   Args: {data['function']['arguments']}")
                elif 'status' in data:
                    # Status update
                    events.append(f"📊 Status: {data['status']}")
                elif 'metadata' in data:
                    # Metadata update
                    metadata.update(data['metadata'])
                else:
                    # Other structured data
                    logger.debug(f"SSE Data: {data}")
            else:
                # Plain text data
                current_content.append(str(data))
                
        elif parsed['type'] == 'done':
            events.append("✅ Stream completed")
            break
    
    # Format the response
    result_parts = []
    
    # Add events section if there were any
    if events:
        result_parts.append("## 🎯 Events")
        result_parts.extend(events)
        result_parts.append("")  # Empty line
    
    # Add main content
    if current_content:
        result_parts.append("## 💬 Response")
        result_parts.append(''.join(current_content))
        result_parts.append("")  # Empty line
    
    # Add metadata if present
    if metadata:
        result_parts.append("## 📋 Metadata")
        for key, value in metadata.items():
            result_parts.append(f"- **{key}**: {value}")
    
    return '\n'.join(result_parts)


def create_chat_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create chat-related MCP tools"""
    
    @mcp.tool(
        name="ask_one",
        description="Ask a question to a Percolate agent and stream the response with event information",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": False},
            "tags": ["chat", "agent", "stream", "question"]
        }
    )
    async def ask_one(params: AskOneParams) -> str:
        """Ask a question and return formatted streaming response"""
        from ..config import get_mcp_settings
        settings = get_mcp_settings()
        
        # Use defaults from settings
        agent = params.agent or settings.default_agent
        model = params.model or settings.default_model
        
        # Stream the chat response
        stream = await repository.stream_chat(
            query=params.query,
            agent=agent,
            model=model,
            session_id=params.session_id,
            stream=params.stream
        )
        
        # Format and return the streamed response
        return await format_streamed_response(stream)