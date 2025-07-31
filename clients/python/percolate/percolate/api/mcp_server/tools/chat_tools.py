"""Chat tools for MCP - streaming agent interactions"""

from typing import Optional, Dict, Any, List, AsyncIterator, Union
from pydantic import BaseModel, Field
from fastmcp import FastMCP, Context
from ..base_repository import BaseMCPRepository
import json
import logging
import asyncio
from datetime import datetime, timezone

logger = logging.getLogger(__name__)


class AskOneParams(BaseModel):
    """Parameters for ask_one tool"""
    query: str = Field(
        ...,
        description="The question or prompt to send to the agent"
    )
    agent: Optional[str] = Field(
        None,
        description="The agent to use. If not provided or set to 'p8-PercolateAgent', uses the configured P8_DEFAULT_AGENT from extension settings"
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


async def process_streaming_response(stream: Union[str, AsyncIterator[str]], ctx: Optional[Context] = None) -> Dict[str, Any]:
    """Process streaming response and return structured data with content and context"""
    
    # Handle non-streaming response
    if isinstance(stream, str):
        return {
            "content": stream,
            "events": [],
            "metadata": {},
            "stream_completed": True
        }
    
    # Process streaming response
    events = []
    content_parts = []
    metadata = {}
    function_calls = []
    stream_completed = False
    
    try:
        async for line in stream:
            parsed = parse_sse_line(line)
            if not parsed:
                continue
                
            if parsed['type'] == 'event':
                event_name = parsed['value']
                events.append({
                    "type": "event",
                    "name": event_name,
                    "timestamp": datetime.now(timezone.utc).isoformat()
                })
                logger.debug(f"SSE Event: {event_name}")
                if ctx:
                    await ctx.info(f"🔸 Event: {event_name}")
                
            elif parsed['type'] == 'data':
                data = parsed['value']
                if isinstance(data, dict):
                    # Handle different data types
                    if 'choices' in data:
                        # OpenAI-style streaming response
                        for choice in data.get('choices', []):
                            delta = choice.get('delta', {})
                            if 'content' in delta and delta['content']:
                                content_parts.append(delta['content'])
                            if 'tool_calls' in delta:
                                for tool_call in delta['tool_calls']:
                                    function_calls.append({
                                        "type": "function_call",
                                        "function": tool_call.get('function', {}),
                                        "id": tool_call.get('id'),
                                        "timestamp": datetime.now(timezone.utc).isoformat()
                                    })
                                    if ctx:
                                        func_name = tool_call.get('function', {}).get('name', 'unknown')
                                        await ctx.info(f"🔧 Function call: {func_name}")
                    elif 'content' in data:
                        # Direct content chunk
                        content_parts.append(data['content'])
                    elif 'function' in data:
                        # Function call event
                        function_calls.append({
                            "type": "function_call",
                            "function": data['function'],
                            "timestamp": datetime.now(timezone.utc).isoformat()
                        })
                        if ctx:
                            func_name = data['function'].get('name', 'unknown')
                            await ctx.info(f"🔧 Function call: {func_name}")
                    elif 'status' in data:
                        # Status update
                        events.append({
                            "type": "status",
                            "status": data['status'],
                            "timestamp": datetime.now(timezone.utc).isoformat()
                        })
                        if ctx:
                            await ctx.info(f"📊 Status: {data['status']}")
                    elif 'metadata' in data:
                        # Metadata update
                        metadata.update(data['metadata'])
                    elif 'error' in data:
                        # Error event
                        events.append({
                            "type": "error",
                            "error": data['error'],
                            "timestamp": datetime.now(timezone.utc).isoformat()
                        })
                        if ctx:
                            await ctx.error(f"❌ Error: {data['error']}")
                    else:
                        # Other structured data
                        logger.debug(f"Unhandled SSE Data: {data}")
                else:
                    # Plain text data
                    content_parts.append(str(data))
                    
            elif parsed['type'] == 'done':
                stream_completed = True
                events.append({
                    "type": "stream_complete",
                    "timestamp": datetime.now(timezone.utc).isoformat()
                })
                if ctx:
                    await ctx.info("✅ Stream completed")
                break
                
    except Exception as e:
        logger.error(f"Error processing stream: {e}")
        events.append({
            "type": "error",
            "error": str(e),
            "timestamp": datetime.now(timezone.utc).isoformat()
        })
        if ctx:
            await ctx.error(f"Error processing stream: {str(e)}")
    
    # Combine all content
    full_content = ''.join(content_parts)
    
    # Build the response structure
    response = {
        "content": full_content,
        "events": events,
        "metadata": metadata,
        "stream_completed": stream_completed
    }
    
    # Add function calls if any
    if function_calls:
        response["function_calls"] = function_calls
    
    return response


def format_response_as_markdown(response: Dict[str, Any]) -> str:
    """Format the structured response as markdown for display"""
    parts = []
    
    # Add main content
    content = response.get('content', '')
    if content:
        parts.append("## 💬 Response")
        parts.append(content)
        parts.append("")  # Empty line
    
    # Add events if any
    events = response.get('events', [])
    if events:
        parts.append("## 🎯 Events")
        for event in events:
            event_type = event.get('type', 'unknown')
            if event_type == 'event':
                parts.append(f"🔸 {event.get('name', 'Unknown event')}")
            elif event_type == 'status':
                parts.append(f"📊 Status: {event.get('status', 'Unknown')}")
            elif event_type == 'error':
                parts.append(f"❌ Error: {event.get('error', 'Unknown error')}")
            elif event_type == 'stream_complete':
                parts.append("✅ Stream completed")
        parts.append("")  # Empty line
    
    # Add function calls if any
    function_calls = response.get('function_calls', [])
    if function_calls:
        parts.append("## 🔧 Function Calls")
        for call in function_calls:
            func = call.get('function', {})
            func_name = func.get('name', 'Unknown function')
            parts.append(f"- **{func_name}**")
            if 'arguments' in func:
                parts.append(f"  Args: {func.get('arguments', {})}")
        parts.append("")  # Empty line
    
    # Add metadata if present
    metadata = response.get('metadata', {})
    if metadata:
        parts.append("## 📋 Metadata")
        for key, value in metadata.items():
            parts.append(f"- **{key}**: {value}")
    
    return '\n'.join(parts)


def create_chat_tools(mcp: FastMCP, repository: BaseMCPRepository):
    """Create chat-related MCP tools"""
    
    @mcp.tool(
        name="ask_stream",
        description="Ask a question to a Percolate agent with real-time streaming updates",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": False},
            "tags": ["chat", "agent", "stream", "question", "realtime"]
        }
    )
    async def ask_stream(
        query: str,
        ctx: Context,
        agent: Optional[str] = None,
        model: Optional[str] = None,
        session_id: Optional[str] = None
    ) -> str:
        """Ask a question with real-time streaming updates via Context"""
        from ..config import get_mcp_settings
        settings = get_mcp_settings()
        
        # Use defaults from settings
        if not agent or agent == 'p8-PercolateAgent':
            agent = settings.default_agent
            
        model = model or settings.default_model
        
        try:
            # Notify start
            await ctx.info(f"🚀 Starting chat with {agent}")
            await ctx.debug(f"Query: {query}")
            
            # Get the stream
            await ctx.debug(f"📡 Calling repository.stream_chat with:")
            await ctx.debug(f"  - agent: {agent}")
            await ctx.debug(f"  - model: {model}")
            await ctx.debug(f"  - session_id: {session_id}")
            
            stream_response = await repository.stream_chat(
                query=query,
                agent=agent,
                model=model,
                session_id=session_id,
                stream=True
            )
            
            await ctx.debug(f"✅ Got stream response: {type(stream_response)}")
            
            # Process stream and emit updates
            content_buffer = []
            event_count = 0
            line_count = 0
            
            async for line in stream_response:
                line_count += 1
                if line_count <= 5 or line_count % 50 == 0:
                    await ctx.debug(f"📥 Line {line_count}: {line[:100]}...")
                parsed = parse_sse_line(line)
                if not parsed:
                    if line_count <= 5:
                        await ctx.debug(f"⚠️  Unparsed line: {line}")
                    continue
                    
                if parsed['type'] == 'event':
                    event_name = parsed['value']
                    event_count += 1
                    await ctx.info(f"🔸 Event: {event_name}")
                    
                elif parsed['type'] == 'data':
                    data = parsed['value']
                    if isinstance(data, dict):
                        # Handle OpenAI-style streaming
                        if 'choices' in data:
                            for choice in data.get('choices', []):
                                delta = choice.get('delta', {})
                                if 'content' in delta and delta['content']:
                                    chunk = delta['content']
                                    content_buffer.append(chunk)
                                    # Emit chunks periodically for ctx updates
                                    if ctx and len(content_buffer) % 10 == 0:
                                        await ctx.debug(f"Received {len(content_buffer)} chunks...")
                                        
                                if 'tool_calls' in delta:
                                    for tool_call in delta['tool_calls']:
                                        func_name = tool_call.get('function', {}).get('name', 'unknown')
                                        await ctx.info(f"🔧 Function call: {func_name}")
                                        
                        elif 'content' in data:
                            # Direct content chunk
                            content_buffer.append(data['content'])
                            
                        elif 'error' in data:
                            await ctx.error(f"❌ Error: {data['error']}")
                            
                elif parsed['type'] == 'done':
                    await ctx.info("✅ Stream completed")
                    break
            
            # Combine all content
            full_content = ''.join(content_buffer)
            
            # Log summary
            await ctx.info(f"📊 Response complete: {len(full_content)} characters, {event_count} events")
            
            # Return the final content
            return full_content
            
        except Exception as e:
            await ctx.error(f"Error in streaming: {str(e)}")
            logger.error(f"Error in ask_stream tool: {e}")
            return f"Error: {str(e)}"
    
    @mcp.tool(
        name="ask_the_agent",
        description="Ask deeper questions about the company/data this MCP server is configured for. Get insights, analysis, and detailed information through the AI agent.",
        annotations={
            "hint": {"readOnlyHint": True, "idempotentHint": False},
            "tags": ["chat", "agent", "stream", "question", "insights", "analysis"]
        }
    )
    async def ask_the_agent(
        query: str,
        ctx: Context,
        agent: Optional[str] = None,
        model: Optional[str] = None,
        session_id: Optional[str] = None,
        stream: bool = True
    ) -> str:
        """Ask deeper questions to the AI agent for insights about your company data"""
        from ..config import get_mcp_settings
        settings = get_mcp_settings()
        
        # Use defaults from settings
        if not agent or agent == 'p8-PercolateAgent':
            agent = settings.default_agent
            
        model = model or settings.default_model
        
        try:
            # Notify start
            await ctx.info(f"🚀 Starting chat with {agent}")
            
            # Stream the chat response
            stream_response = await repository.stream_chat(
                query=query,
                agent=agent,
                model=model,
                session_id=session_id,
                stream=stream
            )
            
            # Notify start
            await ctx.info(f"🔍 Processing response...")
            
            # Process the response with context for real-time updates
            result = await process_streaming_response(stream_response, ctx)
            
            # Format as markdown
            return format_response_as_markdown(result)
            
        except Exception as e:
            logger.error(f"Error in ask tool: {e}")
            return f"❌ Error: {str(e)}"
    
