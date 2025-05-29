"""
Utility functions for the proxy module.

This module contains utility classes and functions for:
1. Background audit processing
2. Response parsing and formatting
3. Stream handling helpers
"""

import json
import threading
import typing
import uuid
import time
from pydantic import BaseModel
from percolate.utils import logger
from percolate.models import AIResponse, Session
import percolate as p8

class BackgroundAudit:
    """
    Background audit processor for AIResponse records.
    
    This sends AIResponse audit records on a background thread to avoid blocking
    the user stream. Used by higher level classes that construct their own AIResponse
    turns consisting of both tool calls from the LLM and local evaluation data.
    
    This auditor is designed to make streaming efficient while supporting full 
    auditing in the memory proxy.
    """
    
    def __init__(self):
        """Initialize the background auditor."""
        self._queue = []
        self._lock = threading.Lock()
        self._thread = None
        self._stop_event = threading.Event()
    
    def add_response(self, response: AIResponse) -> None:
        """
        Add an AIResponse to the audit queue.
        
        Args:
            response: The AIResponse to audit
        """
        with self._lock:
            self._queue.append(("ai_response", response))
            if not self._thread or not self._thread.is_alive():
                self._start_worker()
    
    def add_session(self, session_data: dict) -> None:
        """
        Add a session record to the audit queue.
        
        Args:
            session_data: The session data to audit
        """
        with self._lock:
            self._queue.append(("session", session_data))
            if not self._thread or not self._thread.is_alive():
                self._start_worker()
    
    def _start_worker(self) -> None:
        """Start the background worker thread."""
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._process_queue, daemon=True)
        self._thread.start()
    
    def _process_queue(self) -> None:
        """Process the queue of audit records."""
        
        while not self._stop_event.is_set():
            with self._lock:
                if not self._queue:
                    break
                records = self._queue.copy()
                self._queue.clear()
            
            try:
                ai_responses = []
                session_records = []
                
                # Separate records by type
                for record_type, record in records:
                    if record_type == "ai_response":
                        ai_responses.append(record)
                    elif record_type == "session":
                        session_records.append(record)
                
                # Process AI responses
                if ai_responses:
                    p8.repository(AIResponse).update_records(ai_responses)
                    logger.debug(f"Audited {len(ai_responses)} AIResponse records")
                
                # Process sessions
                if session_records:
                    p8.repository(Session).update_records(session_records)
                    logger.debug(f"Audited {len(session_records)} Session records")
            except Exception as e:
                logger.error(f"Error processing audit queue: {e}")
            
            # Small sleep to avoid tight loop
            time.sleep(0.1)
    
    def stop(self) -> None:
        """Stop the background worker thread."""
        self._stop_event.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)
    
    
    def flush_ai_response_audit(
        self,
        content: str,
        tool_calls: typing.List[dict],
        tool_responses: typing.Dict[str, dict],
        usage: typing.Dict[str, int]
    ) -> None:
        """
        Flush AI response data to audit storage.
        
        This helper constructs an AI response and flushes it on a background thread.
        These are turns with request-response that can be used for auditing or memory.
        
        Args:
            content: The text content
            tool_calls: List of tool calls
            tool_responses: Dictionary of tool responses by tool call ID
            usage: Token usage information
        """

        ai_response = AIResponse(
            id=str(uuid.uuid4()),
            model_name="unknown",  # Required field
            role="assistant",
            content=content,
            status="TOOL_CALLS" if tool_calls else "RESPONSE",
            tool_calls=tool_calls,
            tool_eval_data=tool_responses,
            tokens_in=usage.get("prompt_tokens", 0),
            tokens_out=usage.get("completion_tokens", 0)
        )
        
        # Add to audit queue
        self.add_response(ai_response)
    
    @classmethod
    def audit_user_session(cls, 
                           session_id: str, 
                           user_id: str = None, 
                           channel_id: str = None,
                           query: str = None) -> None:
        """
        Audit a user session without creating an AIResponse.
        This method only creates or updates a Session record in the background.
        
        Args:
            session_id: The session ID
            user_id: Optional user ID
            channel_id: Optional channel ID
            query: Optional user query
        """
        # Create a session record
        session_data = {
            'id': session_id,
            'user_id': user_id,
            'channel_id': channel_id,
            'last_activity': time.time(),
            'query': query
        }
        
        # Add to the background auditor
        auditor = cls()
        auditor.add_session(session_data)


def parse_sse_line(line: str) -> typing.Optional[dict]:
    """
    Parse a server-sent event line into a JSON object.
    
    Args:
        line: The SSE line starting with 'data: '
        
    Returns:
        The parsed JSON object or None if parsing failed
    """
    if not line or not line.startswith("data: "):
        return None
    
    data = line[6:].strip()
    if data == "[DONE]":
        return {"type": "done"}
    
    try:
        return json.loads(data)
    except json.JSONDecodeError:
        return None


def create_sse_line(data: typing.Union[dict, str]) -> str:
    """
    Create a server-sent event line from data.
    
    Args:
        data: The data to convert to an SSE line
        
    Returns:
        An SSE formatted line
    """
    if isinstance(data, dict):
        data = json.dumps(data)
    return f"data: {data}\n\n"


def format_tool_calls_for_openai(tool_calls: typing.List[dict]) -> typing.List[dict]:
    """
    Format tool calls to match the OpenAI API format.
    
    Args:
        tool_calls: List of tool calls in any format
        
    Returns:
        Tool calls in OpenAI format
    """
    openai_tool_calls = []
    
    for i, call in enumerate(tool_calls):
        # Extract function data
        if "function" in call:
            function = call["function"]
        else:
            # For Anthropic-style tool calls
            function = {
                "name": call.get("name", ""),
                "arguments": json.dumps(call.get("input", {}))
            }
        
        # Create OpenAI format tool call
        openai_tool_calls.append({
            "index": i,
            "id": call.get("id", f"call_{str(uuid.uuid4())[:16]}"),
            "type": "function",
            "function": {
                "name": function.get("name", ""),
                "arguments": function.get("arguments", "{}")
            }
        })
    
    return openai_tool_calls


def audit_response_for_user(response, context, query: str = None):
    """
    Audit an LLM response for a user based on context information.
    
    This function creates audit records for both the session and the user model,
    and handles AIResponse objects if they exist in the response. It's designed to work
    with LLMStreamIterator or similar response objects that have been collected
    into a complete response.
    
    Args:
        response: The complete response object with content and usage information
        context: The CallingContext object containing user information
        query: Optional query string if not available from context
    
    Returns:
        None
    """
    try:
        from percolate.models import Session, User, AIResponse
        from percolate.utils import make_uuid, logger
        import percolate as p8
        
        # Extract user information from context
        user_id = None
        if context.user_id:
            user_id = context.user_id
        elif context.username:
            # Try to resolve username to user_id
            if '@' in context.username:
                # Treat as email and hash it
                user_id = make_uuid(context.username.lower())
            else:
                # Try to lookup the user by username or ID
                try:
                    query_id_or_email = "SELECT * FROM p8.\"User\" WHERE id::TEXT = %s OR email = %s"
                    user_result = p8.repository(User).execute(
                        query_id_or_email, 
                        data=(context.username, context.username)
                    )
                    if user_result:
                        user_id = user_result[0]['id']
                except Exception as e:
                    logger.warning(f"Failed to lookup user by username: {e}")
        
        # Get response content and session information
        content = getattr(response, 'content', str(response))
        
        # Make sure we have a valid session_id
        session_id = getattr(response, 'session_id', None)
        if not session_id and context:
            session_id = getattr(context, 'session_id', None)
        if not session_id:
            session_id = str(uuid.uuid4())
            logger.debug(f"Generated new session_id for audit: {session_id}")
        
        # Prepare metadata
        channel_ts = getattr(context, 'channel_ts', None) if context else None
        thread_id = getattr(context, 'session_id', None) if context else None
        
        metadata = {
            'userid': user_id,
            'channel_id': channel_ts,
            'thread_id': thread_id,
            'query': query or (getattr(context, 'plan', '') if context else '')
        }
        
        # Audit Session
        try:
            session = Session(id=session_id, **metadata)
            p8.repository(Session).update_records(session)
            logger.info(f"Audited session: {session_id} for metadata {metadata}")
        except Exception as e:
            logger.warning(f"Problem with audit session: {e}")
        
        # Update user model if we have a user ID
        if user_id:
            try:
                # Get the response content for user model update
                response_content = str(content)
                p8.repository(User).execute(
                    'SELECT * FROM p8.update_user_model(%s, %s)', 
                    data=(user_id, response_content)
                )
                logger.info(f"Updated user model for: {user_id}")
            except Exception as e:
                logger.warning(f"Problem updating user model: {e}")
        else:
            logger.warning("No user ID available for user model update")
        
        # Audit AI responses if present
        try:
            if hasattr(response, 'ai_responses') and response.ai_responses:
                p8.repository(AIResponse).update_records(response.ai_responses)
                logger.debug(f"Added {len(response.ai_responses)} AI Response records")
        except Exception as e:
            logger.warning(f"Problem with AI response audit: {e}")
    
    except Exception as e:
        logger.error(f"Error in audit_response_for_user: {e}")
        import traceback
        logger.error(traceback.format_exc())