# OpenTelemetry Observability for Percolate

This document describes how Percolate implements OpenTelemetry (OTel) instrumentation for GenAI observability, providing comprehensive tracking of model executions, costs, and user sessions.

## Overview

Percolate uses OpenTelemetry to instrument:
- **LLM Generations**: Model calls with token usage, costs, prompts, and completions
- **Tool Calls**: Function executions within agent workflows
- **User Context**: User IDs and session IDs for request attribution
- **Session Feedback**: User feedback (thumbs up/down) on chat sessions

## Configuration

### Environment Variables

Enable OpenTelemetry instrumentation with the `OTEL_ENABLED` environment variable:

```bash
# Enable OTel (default: false)
export OTEL_ENABLED=true

# Standard OTel environment variables
export OTEL_SERVICE_NAME=percolate
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

**Default Behavior**: OTel is disabled by default (`OTEL_ENABLED=false`). This ensures zero overhead when observability is not required.

### ConfigMap Configuration

For Kubernetes deployments, enable OTel via ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: percolate-config
  namespace: p8
data:
  OTEL_ENABLED: "true"
  OTEL_SERVICE_NAME: "percolate"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
```

## Semantic Conventions

Percolate follows both the [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) and [OpenInference Semantic Conventions](https://arize-ai.github.io/openinference/spec/semantic_conventions.html) for standardized AI observability.

### OpenInference Span Kinds (Phoenix-Specific)

Phoenix uses the `openinference.span.kind` attribute to categorize and visualize different types of AI operations:

- **LLM** - Large language model API calls (automatically set for all LLM operations)
- **AGENT** - Autonomous agent operations and workflows
- **TOOL** - Function/tool calls used by agents
- **CHAIN** - Workflow steps, sequences, or pipeline operations
- **RETRIEVER** - Vector search, document retrieval, or RAG operations
- **RERANKER** - Document reranking operations
- **EMBEDDING** - Text or multimodal embedding generation

These span kinds are automatically set by Percolate's instrumentation:
- `set_llm_attributes()` → Sets `openinference.span.kind = "LLM"`
- Agent streaming operations → Sets `openinference.span.kind = "AGENT"`
- Tool invocations → Sets `openinference.span.kind = "TOOL"`

### OpenTelemetry GenAI Attributes

#### LLM Model Attributes
- `gen_ai.request.model` - Model identifier (e.g., "gpt-4o", "claude-3.5-sonnet")
- `gen_ai.response.model` - Model that actually responded
- `gen_ai.system` - Provider name (e.g., "openai", "anthropic")

#### Token Usage
- `gen_ai.usage.input_tokens` - Number of input/prompt tokens
- `gen_ai.usage.output_tokens` - Number of output/completion tokens
- `gen_ai.usage.total_tokens` - Total tokens (input + output)

#### Cost Tracking
- `gen_ai.usage.input_cost` - Cost for input tokens in USD
- `gen_ai.usage.output_cost` - Cost for output tokens in USD
- `gen_ai.usage.cost` - Total cost in USD

#### Generation Parameters
- `gen_ai.request.max_tokens` - Maximum output tokens requested
- `gen_ai.request.temperature` - Sampling temperature
- `gen_ai.response.finish_reason` - Reason generation stopped (e.g., "stop", "length")

#### Content Tracking
- `gen_ai.prompt` - The input prompt/messages (Note: Currently not tracked to reduce data volume)
- `gen_ai.completion` - The model's output text (Note: Commented out by default - can be large and contain sensitive data)

#### Streaming
- `gen_ai.is_streaming` - Boolean indicating if streaming was used

### User & Session Context

Percolate extends the standard conventions with session tracking:

- `user.id` - User identifier from CallingContext
- `user.email` - User email from CallingContext (if available)
- `session.id` - Chat session identifier from CallingContext
- `agent.version` - Agent version from model_config metadata (if available)
- `code.filepath` - Source code location (for debugging)

## Implementation Architecture

### ModelRunner Instrumentation

The `ModelRunner` class is instrumented to track all LLM generations and tool calls:

```python
from opentelemetry import trace
from opentelemetry.trace import SpanKind
from percolate.utils.env import OTEL_ENABLED

tracer = trace.get_tracer(__name__)

class ModelRunner:
    def run(self, user_prompt: str, context: CallingContext = None):
        if not OTEL_ENABLED:
            # Skip tracing overhead when disabled
            return self._run_internal(user_prompt, context)

        with tracer.start_as_current_span(
            name="model.generate",
            kind=SpanKind.CLIENT,
            attributes={
                "gen_ai.system": self.provider,
                "gen_ai.request.model": self.model_name,
                "user.id": context.user_id if context else None,
                "session.id": context.session_id if context else None,
            }
        ) as span:
            result = self._run_internal(user_prompt, context)

            # Set generation attributes after completion
            span.set_attribute("gen_ai.usage.input_tokens", result.input_tokens)
            span.set_attribute("gen_ai.usage.output_tokens", result.output_tokens)
            span.set_attribute("gen_ai.usage.cost", result.total_cost_usd)
            span.set_attribute("gen_ai.prompt", user_prompt)
            span.set_attribute("gen_ai.completion", result.text)

            return result
```

### Model Tracking

Models are tracked using their full qualified name from `AbstractModel`:

```python
# Get full model name for tracking
model_full_name = agent_model.get_model_full_name()
# Example: "public.ResearchAgent" or "user123.CustomAgent"

span.set_attribute("gen_ai.request.model", model_full_name)
```

### Context Propagation

The `CallingContext` provides user and session information:

```python
class CallingContext:
    user_id: Optional[str]
    session_id: Optional[str]
    # ... other context fields
```

This context is passed to ModelRunner and propagated to OTel spans for request attribution.

### Cost Auditing Integration

Percolate maintains cost auditing in the database while also emitting costs to OTel:

1. **Database Audit**: Costs are stored in audit tables for billing and reporting
2. **OTel Metrics**: Costs are also emitted as span attributes for real-time observability
3. **Dual Tracking**: Both systems run in parallel for comprehensive cost tracking

```python
# Database audit (existing)
audit_record = {
    "user_id": context.user_id,
    "session_id": context.session_id,
    "cost_usd": total_cost,
    "tokens_used": total_tokens,
    # ...
}
pg.insert_audit(audit_record)

# OTel tracking (new)
if OTEL_ENABLED:
    span.set_attribute("gen_ai.usage.cost", total_cost)
    span.set_attribute("gen_ai.usage.total_tokens", total_tokens)
```

## Session Feedback

User feedback on chat sessions is captured via a dedicated endpoint and instrumented as OTel events.

### Feedback Model

```python
class SessionFeedback(BaseModel):
    session_id: str = Field(..., description="Chat session identifier")
    approved: bool = Field(..., description="User approval (thumbs up=True, thumbs down=False)")
    note: Optional[str] = Field(None, description="Optional feedback note/comment")
    tags: Optional[List[str]] = Field(None, description="Optional labels/badges for categorization")
```

### Feedback Endpoint

```
POST /chat/feedback
```

Request body:
```json
{
    "session_id": "550e8400-e29b-41d4-a716-446655440000",
    "approved": true,
    "note": "Great response, very helpful!",
    "tags": ["accurate", "helpful", "fast"]
}
```

### OTel Instrumentation

Feedback is recorded as a span event:

```python
from opentelemetry import trace

@router.post("/chat/feedback")
async def submit_feedback(feedback: SessionFeedback):
    # Save feedback to database
    save_feedback(feedback)

    # Record as OTel event
    if OTEL_ENABLED:
        span = trace.get_current_span()
        span.add_event(
            name="session.feedback",
            attributes={
                "session.id": feedback.session_id,
                "feedback.approved": feedback.approved,
                "feedback.note": feedback.note or "",
                "feedback.tags": ",".join(feedback.tags) if feedback.tags else "",
            }
        )

    return {"status": "success"}
```

## Helper Functions

Percolate provides helper functions for consistent OTel instrumentation, following patterns from the tribe-ai reference implementation:

### set_llm_attributes

```python
def set_llm_attributes(llm_model_id: str, provider: str) -> dict[str, str]:
    """Prepare standard attributes for an LLM span"""
    return {
        "gen_ai.request.model": llm_model_id,
        "gen_ai.response.model": llm_model_id,
        "gen_ai.system": provider,
    }
```

### set_generation_attributes

```python
def set_generation_attributes(
    span: Span,
    prompt: str,
    completion: str,
    input_tokens: int,
    output_tokens: int,
    input_cost: float,
    output_cost: float,
    total_cost: float,
    temperature: float = None,
    max_tokens: int = None,
    finish_reason: str = None,
):
    """Annotate span with LLM generation metadata"""
    span.set_attribute("gen_ai.prompt", prompt)
    span.set_attribute("gen_ai.completion", completion)
    span.set_attribute("gen_ai.usage.input_tokens", input_tokens)
    span.set_attribute("gen_ai.usage.output_tokens", output_tokens)
    span.set_attribute("gen_ai.usage.total_tokens", input_tokens + output_tokens)
    span.set_attribute("gen_ai.usage.input_cost", input_cost)
    span.set_attribute("gen_ai.usage.output_cost", output_cost)
    span.set_attribute("gen_ai.usage.cost", total_cost)

    if temperature is not None:
        span.set_attribute("gen_ai.request.temperature", temperature)
    if max_tokens is not None:
        span.set_attribute("gen_ai.request.max_tokens", max_tokens)
    if finish_reason:
        span.set_attribute("gen_ai.response.finish_reason", finish_reason)
```

### set_trace_attributes

```python
def set_trace_attributes(
    span: Span,
    user_id: str = None,
    session_id: str = None,
    code_path: str = None,
):
    """Annotate span with user, session, and code context"""
    if user_id:
        span.set_attribute("user.id", user_id)
    if session_id:
        span.set_attribute("session.id", session_id)
    if code_path:
        span.set_attribute("code.filepath", code_path)
```

## Example Usage

### Complete Agent Execution with OTel

```python
from opentelemetry import trace
from opentelemetry.trace import SpanKind
from percolate.utils.env import OTEL_ENABLED

tracer = trace.get_tracer(__name__)

def execute_agent(agent_name: str, user_prompt: str, context: CallingContext):
    # Load agent
    agent_model = Agent.load(agent_name)
    runner = ModelRunner(agent_model)

    if not OTEL_ENABLED:
        return runner.run(user_prompt, context)

    # Create span for agent execution
    with tracer.start_as_current_span(
        name=f"agent.{agent_name}.execute",
        kind=SpanKind.SERVER,
        attributes={
            "agent.name": agent_name,
            "user.id": context.user_id,
            "session.id": context.session_id,
        }
    ) as span:
        # Run agent (ModelRunner will create child spans for LLM calls)
        result = runner.run(user_prompt, context)

        # Track aggregate metrics
        span.set_attribute("agent.total_cost", result.total_cost)
        span.set_attribute("agent.tool_calls_count", len(result.tool_calls))

        return result
```

### Tool Call Tracing

```python
def execute_tool(tool_name: str, arguments: dict, context: CallingContext):
    if not OTEL_ENABLED:
        return tool_registry[tool_name](**arguments)

    with tracer.start_as_current_span(
        name=f"tool.{tool_name}",
        kind=SpanKind.INTERNAL,
        attributes={
            "tool.name": tool_name,
            "tool.arguments": json.dumps(arguments),
            "user.id": context.user_id,
            "session.id": context.session_id,
        }
    ) as span:
        result = tool_registry[tool_name](**arguments)
        span.set_attribute("tool.result", json.dumps(result))
        return result
```

## Observability Platform

Percolate uses **Arize Phoenix** for GenAI observability and tracing. Phoenix is deployed on the cluster and provides comprehensive LLM monitoring, tracing, and evaluation capabilities.

### Arize Phoenix Configuration

Phoenix is the observability backend for Percolate, running on the Kubernetes cluster:

```bash
# Enable OTel for Phoenix
export OTEL_ENABLED=true
export OTEL_SERVICE_NAME=percolate

# Phoenix collector endpoint (deployed on cluster)
export OTEL_EXPORTER_OTLP_ENDPOINT=http://phoenix-collector:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

### Kubernetes ConfigMap

For production deployments, configure Phoenix via ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: percolate-config
  namespace: p8
data:
  OTEL_ENABLED: "true"
  OTEL_SERVICE_NAME: "percolate"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://phoenix-collector:4317"
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
  # Phoenix project organization
  PROJECT_NAME: "percolate"
  DEPLOYMENT_ENVIRONMENT: "production"
```

**Important**: Phoenix uses `openinference.project.name` (not just `project.name`) to organize traces by project. This is automatically set from the `PROJECT_NAME` environment variable during OTEL initialization.

### Phoenix Features

Arize Phoenix provides specialized GenAI observability:

- **LLM Tracing**: Automatic tracing of model calls with token usage and costs
- **Prompt & Response Tracking**: Full visibility into inputs and outputs
- **Evaluation Tools**: Built-in evaluation and quality metrics
- **Cost Analysis**: Real-time cost tracking per model, user, and session
- **Session Replay**: Review complete conversation threads
- **Feedback Integration**: User feedback (thumbs up/down) displayed alongside traces

## Performance Considerations

### Zero Overhead When Disabled
When `OTEL_ENABLED=false` (default), all tracing code is short-circuited with minimal overhead:

```python
if not OTEL_ENABLED:
    return self._execute_without_tracing(...)
```

### Span Creation Best Practices
- Use `SpanKind.SERVER` for entry points (API handlers)
- Use `SpanKind.CLIENT` for external calls (LLM APIs)
- Use `SpanKind.INTERNAL` for internal operations (tool calls)

### Sampling
For high-volume production systems, configure sampling to reduce overhead:

```bash
# Sample 10% of traces
export OTEL_TRACES_SAMPLER=traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1
```

## Metrics and Dashboards

### Key Metrics to Track

1. **Cost Metrics**
   - Total cost per session
   - Cost per model
   - Cost per user

2. **Token Metrics**
   - Tokens per request
   - Input/output token ratio
   - Total tokens per session

3. **Performance Metrics**
   - Request latency (time to first token)
   - Request duration
   - Tool execution time

4. **Quality Metrics**
   - Feedback approval rate
   - Feedback by tags
   - Session success rate

### Example Grafana Dashboard Queries

```promql
# Total cost by model
sum by (gen_ai_request_model) (rate(gen_ai_usage_cost[5m]))

# Average tokens per request
avg(gen_ai_usage_total_tokens)

# Feedback approval rate
sum(session_feedback{approved="true"}) / sum(session_feedback)

# P95 latency by agent
histogram_quantile(0.95, rate(agent_execute_duration_bucket[5m]))
```

## Testing OTel Instrumentation

### Local Testing with Phoenix

1. Start Phoenix locally:
```bash
docker run -d --name phoenix \
  -p 6006:6006 \
  -p 4317:4317 \
  arizephoenix/phoenix:latest
```

2. Enable OTel and run Percolate:
```bash
export OTEL_ENABLED=true
export OTEL_SERVICE_NAME=percolate
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
python -m percolate.api.main
```

3. Execute agent calls and view traces at http://localhost:6006

### Integration Tests

```python
def test_otel_agent_execution():
    import os
    from opentelemetry import trace

    # Enable OTel for test
    os.environ["OTEL_ENABLED"] = "true"

    # Execute agent
    context = CallingContext(user_id="test-user", session_id="test-session")
    result = execute_agent("public.TestAgent", "Hello", context)

    # Verify span was created
    span = trace.get_current_span()
    assert span.get_span_context().is_valid
    assert span.attributes.get("user.id") == "test-user"
    assert span.attributes.get("session.id") == "test-session"
```

## Future Enhancements

### Planned Features
- **Metrics Export**: Export OTel metrics (not just traces) for cost and token aggregation
- **Trace Context Propagation**: Propagate trace context across async tasks and background jobs
- **Custom Events**: Additional event types for agent reasoning steps and decision points
- **Span Links**: Link related spans across sessions for conversation threading

### Community Standards
Percolate follows the evolving [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) and will adopt new standards as they are released, including:
- AI agent-specific conventions (in development, 2025)
- Multi-modal content tracking
- Extended reasoning and chain-of-thought instrumentation

## OpenInference Semantic Conventions Summary

Percolate implements the following OpenInference semantic conventions for Phoenix compatibility:

### Resource Attributes
- `openinference.project.name` - Phoenix project name (set from `PROJECT_NAME` env var)

### Span Attributes
- `openinference.span.kind` - Operation type (LLM, AGENT, TOOL, CHAIN, RETRIEVER, RERANKER, EMBEDDING)

### Automatic Span Kind Assignment
- **LLM calls**: Automatically tagged with `openinference.span.kind = "LLM"` via `set_llm_attributes()`
- **Agent workflows**: Tagged with `openinference.span.kind = "AGENT"` in `ModelRunner.stream()`
- **Tool invocations**: Tagged with `openinference.span.kind = "TOOL"` via `add_tool_call_event()`

### Implementation Locations
- Span kind constants: `percolate/utils/span_kinds.py`
- Helper functions: `percolate/utils/otel_utils.py`
  - `set_span_kind(span, OpenInferenceSpanKind)` - Set span kind
  - `set_llm_attributes(span, model, provider)` - LLM attributes + LLM span kind
  - `add_tool_call_event(span, tool_name, args)` - Tool event + TOOL span kind
- Resource initialization: `percolate/utils/observability.py` - Sets `openinference.project.name`
- Agent instrumentation: `percolate/services/ModelRunner.py` - Sets AGENT span kind

## References

- [OpenInference Semantic Conventions](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)
- [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [Phoenix Documentation](https://docs.arize.com/phoenix)
- [OpenTelemetry Python Documentation](https://opentelemetry.io/docs/instrumentation/python/)
- [GenAI Observability Blog Post](https://opentelemetry.io/blog/2024/otel-generative-ai/)
- [AI Agent Observability Standards](https://opentelemetry.io/blog/2025/ai-agent-observability/)
