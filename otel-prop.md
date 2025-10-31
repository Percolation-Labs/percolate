# OpenTelemetry & Phoenix Integration Improvements for Percolate

## Executive Summary

**Good News**: Percolate already has strong observability foundations:
- ✅ Feedback collection system (`SessionFeedback`, `SessionEvaluation`, `/feedback` endpoint)
- ✅ Token/cost tracking (`TokenUsage`, `AIResponse`)
- ✅ OTEL utility functions with cost/usage attributes
- ✅ Tool call instrumentation in ModelRunner
- ✅ OpenInference span kinds defined

**Critical Gaps** (learned from Tribe Companion Phoenix integration):
1. **Missing LLM instrumentation** - Helper functions exist but not used in `LanguageModel`
2. **No AGENT span wrapping** - ModelRunner needs root AGENT span kind
3. **Feedback NOT sent to Phoenix** - Collected but only saved to DB, not sent to Phoenix annotations API
4. **No span/trace ID linking** - Can't connect feedback to traces in Phoenix

**3-Week Fix**:
- Week 1: Instrument LLM calls and add AGENT spans
- Week 2: Add Phoenix client and link feedback to traces
- Week 3: Testing and documentation

## Current State Analysis

### ✅ What's Already Good

1. **OpenInference Span Kinds**: Already implemented in `span_kinds.py` with proper categories (LLM, AGENT, TOOL, etc.)
2. **OTEL Utilities**: Comprehensive helpers in `otel_utils.py` for setting attributes, events, and span kinds
   - ✅ Cost tracking attributes: `input_cost`, `output_cost`, `total_cost` supported
3. **Resource Attributes**: `observability.py` correctly sets `openinference.project.name` and other Phoenix-required attributes
4. **Tool Instrumentation**: ModelRunner properly instruments tool calls with events and span kinds
5. **No-op Safety**: All OTEL functions gracefully handle disabled state
6. **Feedback Infrastructure**: Already exists!
   - ✅ `SessionFeedback` model for user thumbs up/down (types.py:28-62)
   - ✅ `SessionEvaluation` model for observability storage (types.py:794-809)
   - ✅ `/feedback` POST endpoint (router.py:1406-1476)
   - ✅ Converts feedback to evaluations with ratings (0.0/1.0)
   - ✅ Basic OTEL event instrumentation on feedback submission
7. **Token Usage Tracking**: Already exists!
   - ✅ `TokenUsage` base class (types.py:499-519)
   - ✅ `AIResponse` extends TokenUsage (types.py:564+)
   - ✅ Tracks `tokens_in`, `tokens_out`, `tokens_other`
   - ✅ Session-linked token tracking

### ⚠️ Critical Gaps Identified

Based on the Tribe Companion learnings, we're missing several critical Phoenix integration patterns:

#### 1. **Session Management & Trace Linking** (CRITICAL)
**Problem**: No session tracking tied to traces for feedback annotations

**From eval-update-pr.md (lines 81-102)**:
```python
# Tribe stores span_id in generation_metadata for feedback linking
message_dto.generation_metadata.span_id = agent_response_span_id
```

**What we need**:
- Link session IDs to trace IDs for grouping related conversations
- Capture and store span IDs for feedback annotations
- Set `session.id` attribute on all spans in a session

**Impact**: Without this, feedback annotations cannot be properly linked to traces in Phoenix.

---

#### 2. **Context Propagation Architecture** (HIGH PRIORITY)
**Problem**: No automatic context propagation to ensure all spans get session/user attributes

**From eval-update-pr.md (lines 16-43)**:
```python
class AgentContextSpanProcessor(SpanProcessor):
    def on_start(self, span: Span, parent_context=None) -> None:
        agent_uuid = _agent_uuid_context.get()
        if agent_uuid:
            span.set_attribute("agent_uuid", agent_uuid)
```

**What we need**:
- Create `PercolateContextSpanProcessor` to auto-inject session_id, user_id, agent_version on ALL spans
- Use `contextvars.ContextVar` to propagate context through async call chains
- Set context EARLY in request handlers (before FastAPI creates HTTP span)

**Impact**: Ensures trace completeness - all spans (HTTP, DB, tool calls) get proper context.

---

#### 3. **Missing LLM Call Instrumentation** (CRITICAL)
**Problem**: No evidence of actual LLM call tracing in LanguageModel

**Current**: `otel_utils.py` has helpers but grep found NO usage in `services/llm/`

**What we need**:
- Instrument `LanguageModel._call_raw()` and streaming methods with spans
- Set OpenInference span kind to LLM
- Capture token usage, cost, model, finish_reason
- Record prompt/completion (optional, for debugging)

**Example from Tribe**:
```python
with tracer.start_as_current_span("llm.chat", kind=SpanKind.CLIENT) as span:
    set_span_kind(span, OpenInferenceSpanKind.LLM)
    set_llm_attributes(span, model="gpt-4o", provider="openai")

    # Make LLM call
    response = await client.chat(...)

    # Record usage
    set_generation_attributes(
        span,
        input_tokens=response.usage.input_tokens,
        output_tokens=response.usage.output_tokens,
        total_cost=calculate_cost(response.usage),
        finish_reason=response.finish_reason
    )
```

**Impact**: Without this, Phoenix cannot show LLM calls - the most critical part of agent observability.

---

#### 4. **Agent Execution Spans** (MEDIUM PRIORITY)
**Problem**: No root span wrapping agent.run() or agent.stream()

**From otel-pr.md (lines 108-118)**:
```python
async def respond_streaming(self, agent_request: AgentRequest):
    with tracer.start_as_current_span("respond_streaming"):
        set_span_kind(OpenInferenceSpanKind.AGENT)
        # ... agent logic
```

**What we need**:
- Wrap `ModelRunner.run()` and `ModelRunner.stream()` in spans
- Set `openinference.span.kind = "AGENT"`
- Add attributes: agent.name, agent.version, max_iterations
- Mark as root span for agent execution

**Impact**: Creates proper hierarchy: AGENT → LLM → TOOL

---

#### 5. **Phoenix Annotation Integration** (HIGH PRIORITY for Evals)
**Problem**: Feedback exists but NOT sent to Phoenix as annotations

**Current state**:
- ✅ Feedback collected via `/feedback` endpoint
- ✅ Saved to database as SessionEvaluation
- ✅ Basic OTEL event added to current span
- ❌ NOT sent to Phoenix `/v1/span_annotations` API
- ❌ No span_id/trace_id linking between feedback and original agent execution

**From eval-update-pr.md (lines 472-560)** - Tribe sends to Phoenix:
```python
class PhoenixClient:
    async def send_annotation(self, annotation: PhoenixAnnotation):
        # POST to /v1/span_annotations

annotation = PhoenixAnnotation(
    trace_id=trace_id_hex,  # From original agent execution
    span_id=span_id_hex,    # From original agent execution
    name=f"feedback_positive",
    result={
        "label": "positive",
        "score": 1.0,
        "explanation": user_comment
    },
    metadata={"user_uuid": str(user_id)}
)
```

**What we need**:
- Create `clients/phoenix/client.py` with PhoenixClient
- Store span_id/trace_id in AIResponse or SessionEvaluation when agent runs
- Send feedback to Phoenix annotations API in addition to database
- Link feedback to correct span in Phoenix UI

**Impact**: Makes feedback visible in Phoenix traces - critical for eval workflows.

---

#### 6. **HTTP Request Context Setting** (HIGH PRIORITY)
**Problem**: Context set too late - FastAPI's auto-instrumented HTTP span doesn't get attributes

**From eval-update-pr.md (lines 38-57)**:
```python
# BEFORE: Only child spans got agent_uuid
HTTP POST /api/message ← No agent_uuid (orphaned!)
  └─ agent_response ← Has agent_uuid

# AFTER: All spans get agent_uuid
HTTP POST /api/message ← Has agent_uuid
  └─ agent_response ← Has agent_uuid
```

**What we need**:
- Set context vars at the BEGINNING of route handlers in `api/routes/chat/router.py`
- Before any other operations (even before auth checks)
- Ensure HTTP parent span gets session_id, user_id attributes

**Impact**: Prevents orphaned HTTP spans that can't be filtered/linked.

---

#### 7. **Trace ID Storage** (MEDIUM PRIORITY)
**Problem**: No trace_id captured for linking evaluations/feedback later

**From eval-update-pr.md**: Tribe stores trace_id in message records

**What we need**:
- Capture trace ID at start of agent execution: `get_current_trace_id_as_hex()`
- Store in Session or AIResponse model
- Use for linking feedback/evaluations to traces

**Impact**: Enables offline evaluation linking to traces.

---

## Proposed Changes

### Phase 1: Core Infrastructure (Week 1)

#### 1.1 Context Propagation Processor
**File**: `percolate/utils/otel_context.py` (NEW)

```python
from contextvars import ContextVar
from opentelemetry.sdk.trace import SpanProcessor

# Context vars for propagating metadata
_session_id_context: ContextVar[str | None] = ContextVar("session_id", default=None)
_user_id_context: ContextVar[str | None] = ContextVar("user_id", default=None)
_agent_name_context: ContextVar[str | None] = ContextVar("agent_name", default=None)

class PercolateContextSpanProcessor(SpanProcessor):
    """Automatically inject session/user context into all spans."""

    def on_start(self, span, parent_context=None):
        session_id = _session_id_context.get()
        if session_id:
            span.set_attribute("session.id", session_id)

        user_id = _user_id_context.get()
        if user_id:
            span.set_attribute("user.id", user_id)

        agent_name = _agent_name_context.get()
        if agent_name:
            span.set_attribute("agent.name", agent_name)

def set_session_context(session_id: str, user_id: str = None, agent_name: str = None):
    """Set context for current request - call at start of route handlers."""
    _session_id_context.set(session_id)
    if user_id:
        _user_id_context.set(user_id)
    if agent_name:
        _agent_name_context.set(agent_name)
```

**File**: `percolate/utils/observability.py` (MODIFY)

```python
# Add span processor to provider
from percolate.utils.otel_context import PercolateContextSpanProcessor

def initialize_otel():
    # ... existing setup ...

    # Add context propagation processor
    provider.add_span_processor(PercolateContextSpanProcessor())

    # Existing batch processor
    provider.add_span_processor(BatchSpanProcessor(exporter))
```

#### 1.2 Span/Trace ID Helpers
**File**: `percolate/utils/otel_utils.py` (ADD)

```python
def get_current_span_id_as_hex() -> str | None:
    """Get current span ID in hex format for Phoenix annotations."""
    span = get_current_span()
    if not span:
        return None
    span_id = span.get_span_context().span_id
    return format(span_id, '016x')

def get_current_trace_id_as_hex() -> str | None:
    """Get current trace ID in hex format for linking."""
    span = get_current_span()
    if not span:
        return None
    trace_id = span.get_span_context().trace_id
    return format(trace_id, '032x')
```

### Phase 2: LLM Instrumentation (Week 1)

#### 2.1 Instrument LanguageModel
**File**: `percolate/services/llm/LanguageModel.py` (MODIFY)

Find `_call_raw()` method and wrap with span:

```python
from percolate.utils.otel_utils import (
    get_tracer,
    set_llm_attributes,
    set_generation_attributes,
    is_tracing_enabled,
)
from opentelemetry.trace import SpanKind

tracer = get_tracer(__name__)

class LanguageModel:
    def _call_raw(self, messages, functions=None, context=None):
        """Instrumented LLM call."""

        if not is_tracing_enabled():
            # Existing implementation
            return self._make_llm_call(messages, functions, context)

        # Create LLM span
        with tracer.start_as_current_span(
            "llm.chat",
            kind=SpanKind.CLIENT
        ) as span:
            # Set LLM attributes
            set_llm_attributes(span, model=self.model, provider=self.provider)

            # Add request params
            if context and hasattr(context, 'temperature'):
                span.set_attribute("gen_ai.request.temperature", context.temperature)
            if context and hasattr(context, 'max_tokens'):
                span.set_attribute("gen_ai.request.max_tokens", context.max_tokens)

            # Make the call
            response = self._make_llm_call(messages, functions, context)

            # Extract usage from response
            if hasattr(response, 'usage'):
                set_generation_attributes(
                    span,
                    input_tokens=getattr(response.usage, 'input_tokens', None),
                    output_tokens=getattr(response.usage, 'output_tokens', None),
                    is_streaming=context.streaming if context else False
                )

            return response
```

**Note**: For streaming calls, create span at start, record partial usage in `on_end()` callback.

### Phase 3: Agent & Route Instrumentation (Week 2)

#### 3.1 Instrument ModelRunner
**File**: `percolate/services/ModelRunner.py` (MODIFY)

```python
from percolate.utils.otel_utils import get_tracer, set_span_kind
from percolate.utils.span_kinds import OpenInferenceSpanKind
from opentelemetry.trace import SpanKind

tracer = get_tracer(__name__)

class ModelRunner:
    def run(self, question: str, context=None, **kwargs):
        """Instrumented agent execution."""

        if not is_tracing_enabled():
            return self._run_impl(question, context, **kwargs)

        with tracer.start_as_current_span(
            "agent.run",
            kind=SpanKind.INTERNAL
        ) as span:
            # Set AGENT span kind for Phoenix
            set_span_kind(span, OpenInferenceSpanKind.AGENT)

            # Add agent metadata
            span.set_attribute("agent.name", self.name)
            if hasattr(self.agent_model, 'metadata'):
                version = self.agent_model.metadata.get('version')
                if version:
                    span.set_attribute("agent.version", version)

            # Add session context
            if context and context.session_id:
                span.set_attribute("session.id", context.session_id)
            if context and context.username:
                span.set_attribute("user.id", context.username)

            return self._run_impl(question, context, **kwargs)

    def stream(self, question: str, context=None, **kwargs):
        """Instrumented streaming agent execution."""

        if not is_tracing_enabled():
            yield from self._stream_impl(question, context, **kwargs)
            return

        with tracer.start_as_current_span(
            "agent.stream",
            kind=SpanKind.INTERNAL
        ) as span:
            set_span_kind(span, OpenInferenceSpanKind.AGENT)
            span.set_attribute("agent.name", self.name)

            # Capture span ID for feedback linking
            from percolate.utils.otel_utils import get_current_span_id_as_hex
            span_id = get_current_span_id_as_hex()

            # Store span_id in context for later use
            if context:
                context.span_id = span_id

            yield from self._stream_impl(question, context, **kwargs)
```

#### 3.2 Set Context Early in Routes
**File**: `percolate/api/routes/chat/router.py` (MODIFY)

```python
from percolate.utils.otel_context import set_session_context

@router.post("/chat/completions")
async def chat_completions(
    request: CompletionsRequestOpenApiFormat,
    auth_result = Depends(hybrid_auth),
):
    """Chat completion endpoint with early context setting."""

    # CRITICAL: Set context BEFORE any operations
    # This ensures FastAPI's HTTP span gets the attributes
    session_id = request.metadata.get("session_id") or str(uuid.uuid4())
    user_id = auth_result.get("userid") if auth_result else None

    set_session_context(
        session_id=session_id,
        user_id=user_id,
        agent_name=request.model  # or extract from request
    )

    # Now proceed with normal handling
    response = handle_agent_request(request, params=auth_result)
    return response
```

### Phase 4: Feedback Integration (Week 2)

#### 4.1 Phoenix Client
**File**: `percolate/clients/phoenix/__init__.py` (NEW)

```python
from .client import PhoenixClient, PhoenixAnnotation

__all__ = ["PhoenixClient", "PhoenixAnnotation"]
```

**File**: `percolate/clients/phoenix/client.py` (NEW)

```python
from pydantic import BaseModel
from typing import Optional
import httpx
from percolate.utils import logger

class PhoenixAnnotation(BaseModel):
    """Annotation for Phoenix trace."""
    trace_id: str  # 32-char hex
    span_id: str   # 16-char hex
    name: str      # e.g., "user_feedback_positive"
    annotator_kind: str = "HUMAN"  # or "LLM" for automated evals
    result: dict[str, str | float | None]
    metadata: Optional[dict[str, str]] = None

class PhoenixClient:
    """Client for sending feedback/evals to Phoenix."""

    def __init__(self, base_url: str = "http://localhost:6006"):
        self.base_url = base_url.rstrip("/")
        self.client = httpx.AsyncClient(timeout=10.0)

    async def send_annotation(self, annotation: PhoenixAnnotation) -> bool:
        """Send annotation to Phoenix."""
        try:
            url = f"{self.base_url}/v1/span_annotations"

            # Phoenix requires {"data": [annotation]} wrapper
            payload = {"data": [annotation.model_dump()]}

            response = await self.client.post(url, json=payload)
            response.raise_for_status()

            logger.info(f"Sent annotation to Phoenix: {annotation.name}")
            return True

        except Exception as e:
            logger.warning(f"Failed to send Phoenix annotation: {e}")
            return False

    async def close(self):
        await self.client.aclose()
```

#### 4.2 Store Span IDs for Feedback
**File**: `percolate/models/p8/types.py` (MODIFY)

Add to `AIResponse` class (already extends TokenUsage at line 564):

```python
class AIResponse(TokenUsage):
    # ... existing fields (role, content, status, tool_calls, etc.) ...

    # ADD: Span metadata for linking feedback to Phoenix traces
    span_id: Optional[str] = Field(
        None,
        description="Hex span ID from OTEL for Phoenix annotation linking"
    )
    trace_id: Optional[str] = Field(
        None,
        description="Hex trace ID from OTEL for grouping related spans"
    )
```

Or add to `SessionEvaluation` (line 794) if feedback is session-level:

```python
class SessionEvaluation(AbstractModel):
    # ... existing fields (id, session_id, rating, comments) ...

    # ADD: Link feedback to trace
    span_id: Optional[str] = Field(None, description="OTEL span ID for Phoenix linking")
    trace_id: Optional[str] = Field(None, description="OTEL trace ID for grouping")
```

**File**: `percolate/api/routes/chat/router.py` (MODIFY in agent handler)

In `handle_agent_request()` after agent execution completes:

```python
from percolate.utils.otel_utils import get_current_span_id_as_hex, get_current_trace_id_as_hex

# After agent stream completes, capture span/trace IDs
span_id = get_current_span_id_as_hex()
trace_id = get_current_trace_id_as_hex()

# Store in AIResponse for later feedback linking
if audit_record:
    audit_record.span_id = span_id
    audit_record.trace_id = trace_id
    # Save to database
```

#### 4.3 Enhance Existing Feedback Endpoint
**File**: `percolate/api/routes/chat/router.py` (MODIFY line 1406)

Enhance existing `/feedback` endpoint to send to Phoenix:

```python
from percolate.clients.phoenix import PhoenixClient, PhoenixAnnotation
from percolate.utils.env import PHOENIX_ENABLED, PHOENIX_URL

@router.post("/feedback")
async def submit_feedback(
    feedback: SessionFeedback,
    auth_user_id: Optional[str] = Depends(hybrid_auth),
):
    """Submit user feedback and send to Phoenix (ENHANCED)."""

    # 1. Save feedback to database (EXISTING LOGIC - keep as is)
    evaluation = feedback.to_session_evaluation(user_id=auth_user_id)
    eval_repo = p8.repository(SessionEvaluation, user_id=auth_user_id)
    result = eval_repo.update_records([evaluation])

    # 2. EXISTING OTEL event (keep)
    if OTEL_ENABLED:
        span = trace.get_current_span()
        if span.get_span_context().is_valid:
            span.add_event("session.feedback", attributes={...})

    # 3. NEW: Send to Phoenix if enabled and we have span/trace IDs
    if PHOENIX_ENABLED:
        try:
            # Get span_id and trace_id from AIResponse for this session
            # (assuming we stored them when agent ran)
            ai_response_repo = p8.repository(AIResponse)
            ai_responses = ai_response_repo.execute(
                f"SELECT span_id, trace_id FROM p8.ai_response "
                f"WHERE session_id = '{feedback.session_id}' "
                f"AND span_id IS NOT NULL "
                f"ORDER BY created_at DESC LIMIT 1"
            )

            if ai_responses and ai_responses[0].get('span_id'):
                span_id = ai_responses[0]['span_id']
                trace_id = ai_responses[0]['trace_id']

                client = PhoenixClient(base_url=PHOENIX_URL)
                annotation = PhoenixAnnotation(
                    trace_id=trace_id,
                    span_id=span_id,
                    name=f"user_feedback_{'positive' if feedback.approved else 'negative'}",
                    annotator_kind="HUMAN",
                    result={
                        "label": "positive" if feedback.approved else "negative",
                        "score": 1.0 if feedback.approved else 0.0,
                        "explanation": feedback.note or "",
                    },
                    metadata={
                        "user_id": auth_user_id or "anonymous",
                        "session_id": str(feedback.session_id),
                        "tags": ",".join(feedback.tags) if feedback.tags else "",
                    }
                )

                await client.send_annotation(annotation)
                await client.close()
                logger.info(f"Sent feedback to Phoenix for session {feedback.session_id}")
            else:
                logger.warning(f"No span_id found for session {feedback.session_id}, skipping Phoenix annotation")

        except Exception as phoenix_error:
            # Don't fail feedback submission if Phoenix fails
            logger.warning(f"Failed to send feedback to Phoenix: {phoenix_error}")

    return {
        "status": "success",
        "message": "Feedback submitted successfully",
        "feedback": result[0] if result else feedback.model_dump(),
    }
```

### Phase 5: Configuration & Testing (Week 3)

#### 5.1 Environment Variables
**File**: `percolate/utils/env.py` (ADD)

```python
# Phoenix configuration
PHOENIX_ENABLED = os.getenv("PHOENIX_ENABLED", "false").lower() == "true"
PHOENIX_URL = os.getenv("PHOENIX_URL", "http://localhost:6006")

# OTEL project name (maps to openinference.project.name)
PROJECT_NAME = os.getenv("PROJECT_NAME", "percolate")
```

**File**: `.env.example` (ADD)

```bash
# OpenTelemetry & Phoenix Observability
OTEL_ENABLED=true
OTEL_SERVICE_NAME=percolate
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
PROJECT_NAME=percolate

# Phoenix Feedback Integration (optional)
PHOENIX_ENABLED=true
PHOENIX_URL=http://localhost:6006
```

#### 5.2 Test Trace Script
**File**: `scripts/send-test-trace.sh` (NEW - adapted from Tribe)

```bash
#!/bin/bash
# Send a test trace to verify OTEL → Phoenix pipeline

set -e

OTEL_ENDPOINT="${OTEL_ENDPOINT:-http://localhost:4318}"

# Generate IDs
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
TIMESTAMP_NS=$(date +%s)000000000
END_TIMESTAMP_NS=$((TIMESTAMP_NS + 1000000000))

echo "Sending test trace..."
echo "Trace ID: $TRACE_ID"
echo "Span ID: $SPAN_ID"

curl -X POST "$OTEL_ENDPOINT/v1/traces" \
  -H "Content-Type: application/json" \
  -d "{
    \"resourceSpans\": [{
      \"resource\": {
        \"attributes\": [
          {\"key\": \"service.name\", \"value\": {\"stringValue\": \"percolate-test\"}},
          {\"key\": \"openinference.project.name\", \"value\": {\"stringValue\": \"percolate\"}}
        ]
      },
      \"scopeSpans\": [{
        \"scope\": {\"name\": \"test\", \"version\": \"1.0.0\"},
        \"spans\": [{
          \"traceId\": \"$TRACE_ID\",
          \"spanId\": \"$SPAN_ID\",
          \"name\": \"test-llm-call\",
          \"kind\": 1,
          \"startTimeUnixNano\": \"$TIMESTAMP_NS\",
          \"endTimeUnixNano\": \"$END_TIMESTAMP_NS\",
          \"attributes\": [
            {\"key\": \"openinference.span.kind\", \"value\": {\"stringValue\": \"LLM\"}},
            {\"key\": \"gen_ai.request.model\", \"value\": {\"stringValue\": \"gpt-4\"}},
            {\"key\": \"session.id\", \"value\": {\"stringValue\": \"test-session\"}}
          ]
        }]
      }]
    }]
  }"

echo -e "\n✓ Trace sent! View in Phoenix at http://localhost:6006"
```

#### 5.3 Integration Test
**File**: `test_percolate/integration/otel/test_phoenix_integration.py` (NEW)

```python
"""Integration test for Phoenix observability."""
import pytest
import os
from percolate.models import AbstractModel
import percolate as p8
from percolate.utils.otel_utils import get_current_span_id_as_hex, get_current_trace_id_as_hex

@pytest.mark.skipif(
    os.getenv("OTEL_ENABLED") != "true",
    reason="OTEL not enabled"
)
class TestPhoenixIntegration:

    def test_trace_contains_session_id(self):
        """Verify spans contain session.id attribute."""

        class SimpleAgent(AbstractModel):
            pass

        agent = p8.Agent(SimpleAgent)

        # Set session context
        from percolate.utils.otel_context import set_session_context
        set_session_context(session_id="test-session-123", user_id="test-user")

        response = agent.run("Hello")

        # Verify span was created (check via OTEL SDK or export)
        assert response is not None

    def test_feedback_annotation_format(self):
        """Verify feedback annotation has correct format for Phoenix."""
        from percolate.clients.phoenix import PhoenixAnnotation

        annotation = PhoenixAnnotation(
            trace_id="a" * 32,  # 32 hex chars
            span_id="b" * 16,   # 16 hex chars
            name="user_feedback_positive",
            result={"label": "positive", "score": 1.0}
        )

        data = annotation.model_dump()
        assert data["trace_id"] == "a" * 32
        assert data["annotator_kind"] == "HUMAN"
```

## Revised Implementation Plan (Based on Existing Code)

### What We DON'T Need (Already Working or Not Applicable)

1. **❌ FastAPI HTTP Span Context Propagation** - You're right, ModelRunner manages its own context independent of FastAPI auto-instrumentation. The trace starts with ModelRunner, not the HTTP layer.

2. **❌ Complex Context Propagation Processor** - Not needed if ModelRunner is already the root span with full context.

3. **✅ Token/Cost Tracking** - Already exists in TokenUsage/AIResponse models.

4. **✅ Basic Feedback System** - Already collecting and storing feedback.

### What We DO Need (Critical Gaps)

#### Priority 1: Missing LLM Instrumentation (CRITICAL)
**Current**: Helper functions exist but NOT used in LanguageModel
**Need**: Instrument actual LLM calls in `LanguageModel._call_raw()`

```python
# In LanguageModel._call_raw()
with tracer.start_as_current_span("llm.chat") as span:
    set_llm_attributes(span, model=self.model, provider=self.provider)
    response = self._make_llm_call(...)
    set_generation_attributes(span, input_tokens=..., output_tokens=..., ...)
```

#### Priority 2: Agent Span Wrapping (HIGH)
**Current**: ModelRunner has tool instrumentation but no root AGENT span
**Need**: Wrap `ModelRunner.run()` and `ModelRunner.stream()` with AGENT spans

```python
# In ModelRunner.run() and .stream()
with tracer.start_as_current_span("agent.run") as span:
    set_span_kind(span, OpenInferenceSpanKind.AGENT)
    span.set_attribute("agent.name", self.name)
    # ... existing logic
```

#### Priority 3: Phoenix Feedback Annotations (HIGH)
**Current**: Feedback saved to DB, basic OTEL event added
**Need**:
- Add `span_id`/`trace_id` fields to AIResponse or SessionEvaluation
- Capture span/trace IDs during agent execution
- Send feedback to Phoenix `/v1/span_annotations` API
- Create PhoenixClient

#### Priority 4: Span/Trace ID Helpers (MEDIUM)
**Current**: Not implemented
**Need**: Add to `otel_utils.py`

```python
def get_current_span_id_as_hex() -> str | None:
    span = get_current_span()
    if not span: return None
    return format(span.get_span_context().span_id, '016x')

def get_current_trace_id_as_hex() -> str | None:
    span = get_current_span()
    if not span: return None
    return format(span.get_span_context().trace_id, '032x')
```

## Simplified Implementation Checklist

### Week 1: Core Instrumentation

- [x] Add `get_current_span_id_as_hex()` and `get_current_trace_id_as_hex()` to `otel_utils.py` (ALREADY EXISTED)
- [x] Instrument `LanguageModel._call_raw()` with LLM spans + attributes (ALREADY COMPLETED in call_api_simple lines 622-677)
- [x] Instrument `ModelRunner.run()` with AGENT span kind (COMPLETED - lines 827-851)
- [x] Instrument `ModelRunner.stream()` with AGENT span kind (ALREADY EXISTED - lines 687-730)
- [ ] Test: Verify AGENT → LLM → TOOL hierarchy appears in Phoenix

### Week 2: Feedback → Phoenix Integration

- [x] Create `clients/phoenix/client.py` with PhoenixClient and PhoenixAnnotation (ALREADY EXISTED)
- [x] Store span/trace IDs in Session.metadata for feedback linking (COMPLETED - ModelRunner._capture_span_ids_to_session_metadata)
- [x] Capture and store span/trace IDs in ModelRunner when agent executes (COMPLETED - called in both run() and stream())
- [x] Enhance `/feedback` endpoint to send annotations to Phoenix (COMPLETED - router.py lines 1465-1504)
- [x] Add `PHOENIX_ENABLED` and `PHOENIX_URL` env vars (COMPLETED - env.py lines 100-101)
- [ ] Test: Submit feedback and verify annotation appears in Phoenix UI

### Week 3: Testing & Documentation
- [ ] Create `scripts/send-test-trace.sh` for OTLP testing
- [ ] Write integration test: `test_percolate/integration/otel/test_phoenix_feedback.py`
- [ ] Update `docs/10-observability-with-otel.md` with Phoenix feedback flow
- [ ] Test end-to-end: Agent run → Feedback → Phoenix annotation linkage

## Implementation Notes - 2025 Update

### What Was Actually Implemented

#### 1. **Span ID Capture & Storage** ✅
**Files Modified:**
- `ModelRunner.py` (lines 415-456): Added `_capture_span_ids_to_session_metadata()` helper method
- `ModelRunner.py` (lines 709-710, 848-849): Called helper in both `stream()` and `run()` methods
- **Storage Location**: Session.metadata JSON field (keys: `otel_span_id`, `otel_trace_id`)
- **No schema changes required** - uses existing metadata field

#### 2. **Agent Span Instrumentation** ✅
**Files Modified:**
- `ModelRunner.stream()` (lines 687-730): Already had AGENT span wrapping
- `ModelRunner.run()` (lines 763-851): **NEW** - Added AGENT span wrapping with proper attributes
- Both methods now:
  - Set `OpenInferenceSpanKind.AGENT` for Phoenix categorization
  - Add `agent.name`, `agent.version`, `agent.max_iterations` attributes
  - Call `_capture_span_ids_to_session_metadata()` for feedback linking

#### 3. **LLM Instrumentation** ✅
**Files Modified:**
- `LanguageModel.call_api_simple()` (lines 622-677): Already instrumented with:
  - LLM span kind
  - Model, provider, temperature, max_tokens attributes
  - Token usage extraction for non-streaming calls
  - Error marking on HTTP failures

**NOTE**: The plan suggested instrumenting `_call_raw()`, but the actual instrumentation is in `call_api_simple()` which is the correct location since it handles the HTTP request.

#### 4. **Phoenix Feedback Integration** ✅
**Files Modified:**
- `env.py` (lines 100-101): Added `PHOENIX_ENABLED` and `PHOENIX_URL` config
- `router.py` (lines 1465-1504): Enhanced `/feedback` endpoint to:
  - Retrieve span/trace IDs from session metadata
  - Call `PhoenixClient.send_feedback_annotation()`
  - Handle failures gracefully (don't break user feedback flow)
  - Log success/failure for debugging

#### 5. **Phoenix Client** ✅
**Files Used:**
- `clients/phoenix/client.py`: Already existed with:
  - `PhoenixAnnotation` model
  - `PhoenixClient.send_annotation()` base method
  - `PhoenixClient.send_feedback_annotation()` convenience method for feedback

### Key Design Decisions

1. **No Schema Changes**: Stored span/trace IDs in existing `Session.metadata` JSON field instead of adding new columns
2. **Helper Method Pattern**: Created `_capture_span_ids_to_session_metadata()` to avoid indentation/logic issues in main flow
3. **Graceful Degradation**: All OTEL and Phoenix operations wrapped in try/except to prevent user-facing failures
4. **Session-Level Linking**: Linked feedback to agent execution spans (not individual LLM spans) for clearer UX

### What Still Needs Testing

1. **End-to-End Flow**:
   ```bash
   # 1. Enable tracing
   export OTEL_ENABLED=true
   export PHOENIX_ENABLED=true
   export PHOENIX_URL=http://localhost:6006

   # 2. Run agent and capture session_id
   # 3. Check session metadata has otel_span_id and otel_trace_id
   # 4. Submit feedback via /feedback endpoint
   # 5. Verify annotation appears in Phoenix UI on correct span
   ```

2. **Hierarchy Verification**:
   - AGENT span (from ModelRunner)
   - ├─ LLM span (from LanguageModel.call_api_simple)
   - └─ TOOL span (from ModelRunner.invoke, already instrumented)

3. **Edge Cases**:
   - Feedback submitted before span IDs are stored
   - Session without metadata
   - Phoenix service unavailable
   - OTEL disabled but Phoenix enabled (should gracefully skip)

## Success Criteria

1. **Trace Completeness**: Every agent execution creates AGENT span with child LLM and TOOL spans
2. **Context Propagation**: All spans in a session have `session.id`, `user.id` attributes
3. **Phoenix Categorization**: Spans properly categorized as LLM, AGENT, TOOL in Phoenix UI
4. **Feedback Linking**: User feedback creates annotations visible on correct span in Phoenix
5. **No Orphans**: HTTP request spans have session context (not orphaned)

## Migration Notes

- **Backward Compatible**: All changes are additive, no breaking changes
- **Opt-in**: OTEL remains disabled by default (`OTEL_ENABLED=false`)
- **Graceful Degradation**: All instrumentation no-ops when OTEL disabled
- **Database Changes**: Minimal - only add optional `span_id`/`trace_id` fields

## References

- Tribe eval-update-pr.md: Session/span linking, context propagation, feedback annotations
- Tribe otel-pr.md: OpenInference span kinds, LLM instrumentation
- Tribe send-test-trace.sh: OTLP test payload format
- [Phoenix Semantic Conventions](https://github.com/Arize-ai/openinference/blob/main/spec/semantic_conventions.md)
- [OpenTelemetry GenAI Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
