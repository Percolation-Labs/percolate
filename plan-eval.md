# Phoenix Observability Enhancement Plan - REVISED

## Executive Summary

After reviewing the Percolate codebase, I found that **most of the Phoenix integration is already implemented!** The main gaps are:

1. **Authentication Support**: PhoenixClient and OTLP exporter don't have API key support
2. **Configuration**: Missing PHOENIX_API_KEY and PHOENIX_URL environment variables
3. **Deployment Process**: Need to document build/deploy workflow

**Key Findings**:
- ✅ Feedback endpoint EXISTS (`/chat/feedback` at router.py:1406-1519)
- ✅ PhoenixClient EXISTS (clients/phoenix/client.py)
- ✅ Feedback integration EXISTS (sends to Phoenix in router.py)
- ✅ OTEL configuration EXISTS (ConfigMap has OTEL_ENABLED=true)
- ❌ API key authentication MISSING in both PhoenixClient and OTLP exporter
- ❌ Environment variables for Phoenix auth MISSING

---

## 1. What Already Exists

### 1.1 Feedback Endpoint ✅

**Location**: `percolate/api/routes/chat/router.py:1406-1519`

```python
@router.post("/feedback")
async def submit_feedback(
    feedback: SessionFeedback,
    auth_user_id: Optional[str] = Depends(hybrid_auth),
):
    """Submit user feedback (thumbs up/down) for a chat session."""

    # Converts SessionFeedback to SessionEvaluation
    evaluation = feedback.to_session_evaluation(user_id=auth_user_id)

    # Saves to database
    eval_repo.update_records([evaluation])

    # Instruments with OTEL if enabled
    if OTEL_ENABLED:
        span.add_event("session.feedback", attributes={...})

    # Sends to Phoenix if enabled
    if PHOENIX_ENABLED:
        phoenix_client = PhoenixClient(base_url=PHOENIX_URL)
        await phoenix_client.send_feedback_annotation(...)
```

**What it does**:
- Accepts feedback via POST /chat/feedback
- Saves to SessionEvaluation table
- Instruments as OTEL span event
- **Sends annotation to Phoenix** (but without auth!)

### 1.2 PhoenixClient ✅ (but needs auth)

**Location**: `percolate/clients/phoenix/client.py`

```python
class PhoenixClient:
    def __init__(self, base_url: str) -> None:
        # ❌ MISSING: api_key parameter
        self.base_url = str(base_url).rstrip("/")
        self.annotations_endpoint = f"{self.base_url}/v1/span_annotations"

    async def send_annotation(self, annotation: PhoenixAnnotation) -> bool:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(
                self.annotations_endpoint,
                json=payload,
                # ❌ MISSING: authorization header
            )
```

**What it has**:
- send_annotation() for generic annotations
- send_feedback_annotation() specifically for user feedback
- Proper error handling and logging

**What it's missing**:
- API key parameter in __init__
- Authorization header in requests

### 1.3 OTEL Configuration ✅ (but needs auth headers)

**Location**: `.res/percolate-env-configmap.yaml`

```yaml
# OpenTelemetry
OTEL_ENABLED: "true"
OTEL_SERVICE_NAME: percolate
OTEL_EXPORTER_OTLP_ENDPOINT: http://opentelemetry-collector.observability.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL: grpc

# ❌ MISSING:
# PHOENIX_ENABLED: "true"
# PHOENIX_URL: "http://phoenix.observability.svc.cluster.local:6006"
# PHOENIX_API_KEY: "<will-be-from-secret>"
```

**Location**: `percolate/utils/observability.py:62-65`

```python
exporter = OTLPSpanExporter(
    endpoint=endpoint,
    insecure=True,
    # ❌ MISSING: headers with authorization
)
```

### 1.4 Session Metadata Capture ✅

**Location**: `percolate/services/ModelRunner.py:415-462`

The `_capture_span_ids_to_session_metadata()` method already captures span_id and trace_id to session metadata for feedback linking. This is already working!

---

## 2. Required Changes

### Phase 1: Add Authentication Support (CRITICAL)

#### Task 1.1: Update PhoenixClient with API Key Support

**File**: `percolate/clients/phoenix/client.py`

```python
class PhoenixClient:
    """Client for sending annotations to Phoenix."""

    def __init__(self, base_url: str, api_key: Optional[str] = None) -> None:
        """
        Initialize Phoenix client.

        Args:
            base_url: Base URL for Phoenix API (e.g., http://localhost:6006)
            api_key: Optional API key for authentication
        """
        self.base_url = str(base_url).rstrip("/")
        self.annotations_endpoint = f"{self.base_url}/v1/span_annotations"
        self.spans_endpoint = f"{self.base_url}/v1/spans"
        self.api_key = api_key

    def _get_headers(self) -> dict[str, str]:
        """Get headers for API requests including auth if configured."""
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["authorization"] = f"Bearer {self.api_key}"
        return headers

    async def send_annotation(self, annotation: PhoenixAnnotation) -> bool:
        """Send an annotation to Phoenix."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                payload = {"data": [annotation.model_dump(mode="json")]}
                response = await client.post(
                    self.annotations_endpoint,
                    json=payload,
                    headers=self._get_headers(),  # ✅ ADD AUTH HEADER
                )
                response.raise_for_status()
                logger.info(f"Successfully sent annotation to Phoenix for trace {annotation.trace_id}")
                return True
        except httpx.HTTPStatusError as e:
            logger.warning(f"Failed to send annotation to Phoenix: {e}")
            return False
```

**Changes**:
1. Add `api_key: Optional[str] = None` parameter to `__init__`
2. Add `_get_headers()` method that includes Bearer token if api_key is set
3. Update `send_annotation()` to use `headers=self._get_headers()`

#### Task 1.2: Update Environment Variables

**File**: `percolate/utils/env.py` (add after line 100)

```python
# Phoenix configuration for observability feedback
PHOENIX_ENABLED = os.environ.get("PHOENIX_ENABLED", "true").lower() in ("true", "1", "yes", "y")
PHOENIX_URL = os.environ.get("PHOENIX_URL", "http://phoenix.observability.svc.cluster.local:6006")
PHOENIX_API_KEY = os.environ.get("PHOENIX_API_KEY")  # ✅ ADD THIS
```

#### Task 1.3: Update Feedback Endpoint to Use API Key

**File**: `percolate/api/routes/chat/router.py:1486` (update PhoenixClient initialization)

```python
# Send feedback to Phoenix if enabled
try:
    from percolate.utils.env import PHOENIX_ENABLED, PHOENIX_URL, PHOENIX_API_KEY
    from percolate.clients.phoenix.client import PhoenixClient

    if PHOENIX_ENABLED:
        # ... existing code to get span/trace IDs ...

        # ✅ PASS API KEY
        phoenix_client = PhoenixClient(
            base_url=PHOENIX_URL,
            api_key=PHOENIX_API_KEY
        )
        success = await phoenix_client.send_feedback_annotation(...)
```

#### Task 1.4: Add Authentication to OTLP Exporter

**File**: `percolate/utils/observability.py:40-70`

```python
def initialize_otel():
    """Initialize OpenTelemetry tracing if OTEL_ENABLED is true."""
    if not OTEL_ENABLED:
        logger.info("OpenTelemetry tracing is disabled (OTEL_ENABLED=false)")
        return None

    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.sdk.resources import Resource

        # Get configuration from environment
        service_name = os.environ.get("OTEL_SERVICE_NAME", "percolate")
        endpoint = os.environ.get(
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "http://localhost:4317"
        )
        project_name = os.environ.get("PROJECT_NAME", "percolate")
        deployment_env = os.environ.get("DEPLOYMENT_ENVIRONMENT", "development")

        # ✅ ADD: Get Phoenix API key for OTLP authentication
        phoenix_api_key = os.environ.get("PHOENIX_API_KEY")

        # Create resource with service name and Phoenix project organization
        resource = Resource(attributes={
            "service.name": service_name,
            "service.version": "1.0.0",
            "deployment.environment": deployment_env,
            "openinference.project.name": project_name,
        })

        # Set up tracer provider
        provider = TracerProvider(resource=resource)

        # ✅ ADD: Configure headers with authentication if API key is present
        headers = {}
        if phoenix_api_key:
            # Phoenix requires lowercase 'authorization' for gRPC compatibility
            headers["authorization"] = f"Bearer {phoenix_api_key}"

        # Configure OTLP exporter with authentication
        exporter = OTLPSpanExporter(
            endpoint=endpoint,
            insecure=True,  # For HTTP endpoints (cluster-internal communication)
            headers=headers,  # ✅ ADD AUTH HEADERS
        )

        # Add batch span processor for efficient export
        processor = BatchSpanProcessor(exporter)
        provider.add_span_processor(processor)

        # Set as global tracer provider
        trace.set_tracer_provider(provider)

        logger.info(
            f"OpenTelemetry tracing initialized: service={service_name}, "
            f"endpoint={endpoint}, auth={'enabled' if phoenix_api_key else 'disabled'}"
        )

        return provider
    except ImportError as e:
        logger.warning(f"OpenTelemetry packages not installed: {e}")
        return None
    except Exception as e:
        logger.error(f"Failed to initialize OpenTelemetry: {e}")
        return None
```

#### Task 1.5: Update ConfigMap

**File**: `.res/percolate-env-configmap.yaml` (add to data section)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: percolate-env
  namespace: p8
data:
  # ... existing config ...

  # OpenTelemetry
  OTEL_ENABLED: "true"
  OTEL_SERVICE_NAME: percolate
  OTEL_EXPORTER_OTLP_ENDPOINT: http://opentelemetry-collector.observability.svc.cluster.local:4317
  OTEL_EXPORTER_OTLP_PROTOCOL: grpc

  # ✅ ADD Phoenix Configuration
  PHOENIX_ENABLED: "true"
  PHOENIX_URL: "http://phoenix.observability.svc.cluster.local:6006"
  # Note: PHOENIX_API_KEY will come from a Secret (see below)
```

#### Task 1.6: Create Phoenix Secret

**File**: `.res/phoenix-secret.yaml` (NEW FILE)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: phoenix-api-key
  namespace: p8
type: Opaque
stringData:
  # ⚠️ REPLACE WITH ACTUAL API KEY FROM PHOENIX UI
  # Get this by:
  # 1. kubectl port-forward -n observability svc/phoenix 6006:6006
  # 2. Open http://localhost:6006
  # 3. Login (if auth enabled)
  # 4. Go to Settings → API Keys → Create Key
  PHOENIX_API_KEY: "your-api-key-here"
```

**Apply with**:
```bash
# After creating the API key in Phoenix UI:
kubectl apply -f .res/phoenix-secret.yaml
```

#### Task 1.7: Update Deployment to Use Phoenix Secret

**File**: `.res/app.yaml` (add to env section)

```yaml
spec:
  template:
    spec:
      containers:
        - name: percolate-api
          # ... existing config ...
          env:
            # ... existing env vars ...

            # ✅ ADD Phoenix API Key from Secret
            - name: PHOENIX_API_KEY
              valueFrom:
                secretKeyRef:
                  key: PHOENIX_API_KEY
                  name: phoenix-api-key
          envFrom:
            - configMapRef:
                name: percolate-env
```

---

## 3. Build and Deployment Process

### 3.1 Local Development Workflow

**Location**: From `/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate`

```bash
# 1. Activate poetry environment
poetry shell

# 2. Set up port forwards (run in background)
kubectl port-forward -n p8 service/percolate-rw 25432:5432 > /tmp/port-forward-25432.log 2>&1 &
kubectl port-forward -n observability svc/opentelemetry-collector 4317:4317 > /tmp/otel-collector-forward.log 2>&1 &
kubectl port-forward -n observability svc/phoenix 6006:6006 > /tmp/phoenix-forward.log 2>&1 &

# 3. Set environment variables
export P8_PG_HOST="localhost"
export P8_PG_PORT="25432"
export P8_PG_DATABASE="app"
export P8_PG_USER="postgres"
export P8_PG_PASSWORD="$P8_TEST_BEARER_TOKEN"

# 4. Enable OpenTelemetry with Phoenix
export OTEL_ENABLED=true
export OTEL_SERVICE_NAME=percolate-local
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc

# 5. Configure Phoenix (after creating API key - see below)
export PHOENIX_ENABLED=true
export PHOENIX_URL=http://localhost:6006
export PHOENIX_API_KEY=<your-api-key>

# 6. Run the API locally
uvicorn percolate.api.main:app --port 5008 --reload

# 7. View traces at http://localhost:6006 (Phoenix UI)
```

### 3.2 Creating Phoenix API Key

**Before deploying with auth**, you need to create an API key:

```bash
# 1. Port-forward to Phoenix
kubectl port-forward -n observability svc/phoenix 6006:6006

# 2. Open Phoenix UI
open http://localhost:6006

# 3. If Phoenix has auth enabled:
#    - Login with credentials
#    - If no auth enabled, you'll need to enable it first in the Phoenix deployment

# 4. Go to Settings → API Keys → Create New Key
#    - Give it a name like "percolate-api"
#    - Copy the key (it won't be shown again!)

# 5. Create the secret
kubectl create secret generic phoenix-api-key \
  --from-literal=PHOENIX_API_KEY=<paste-your-key-here> \
  -n p8

# 6. Verify secret was created
kubectl get secret phoenix-api-key -n p8
```

### 3.3 Build and Push Docker Image

**Location**: From `/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate`

```bash
# Build for multi-arch (AMD64 + ARM64) and push to Docker Hub
docker buildx build --platform linux/amd64,linux/arm64 \
  -t percolationlabs/percolate-api:latest \
  --push .
```

**What this does**:
- Builds Docker image for both x86_64 (AMD64) and ARM (ARM64) architectures
- Tags as `percolationlabs/percolate-api:latest`
- Pushes to Docker Hub registry
- Uses Dockerfile in `/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/Dockerfile`

### 3.4 Deploy to Kubernetes

**Location**: From `/Users/sirsh/code/mr_saoirse/percolate`

```bash
# Apply ConfigMap changes (if modified)
kubectl apply -f .res/percolate-env-configmap.yaml

# Apply Phoenix secret (first time only)
kubectl apply -f .res/phoenix-secret.yaml

# Apply deployment changes (if app.yaml was modified)
kubectl apply -f .res/app.yaml

# Restart deployment to pick up new image and configuration
kubectl rollout restart deployment percolate-api -n p8

# Watch rollout status
kubectl rollout status deployment percolate-api -n p8

# Check logs
kubectl logs -l app=percolate-api --all-containers=true --prefix --follow -n p8
```

### 3.5 Verification

```bash
# 1. Check pods are running
kubectl get pods -n p8 -l app=percolate-api

# 2. Check API health
curl -s https://p8.resmagic.io/health

# 3. Check OTEL collector is receiving traces
kubectl logs -n observability -l app=opentelemetry-collector --tail=50

# 4. Port-forward to Phoenix and check UI
kubectl port-forward -n observability svc/phoenix 6006:6006
# Open http://localhost:6006 and verify traces appear

# 5. Test feedback endpoint
curl -X POST https://p8.resmagic.io/chat/feedback \
  -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "test-session-id",
    "approved": true,
    "note": "Test feedback",
    "tags": ["test"]
  }'

# 6. Check Phoenix UI for annotation
# Should see annotation appear in Phoenix for the session
```

---

## 4. tribe/companion Comparison

### What tribe/companion Has That We Need

**From my analysis of tribe/companion implementation:**

1. ✅ **PhoenixClient with API key** - NEED TO ADD (Task 1.1)
   ```python
   PhoenixClient(base_url=url, api_key=key)
   ```

2. ✅ **OTLP exporter with auth headers** - NEED TO ADD (Task 1.4)
   ```yaml
   headers:
     authorization: Bearer ${env:PHOENIX_API_KEY}
   ```

3. ✅ **Context propagation with ContextVar** - NICE TO HAVE (lower priority)
   ```python
   _agent_uuid_context: ContextVar[str | None]
   ```

4. ✅ **AgentContextSpanProcessor** - NICE TO HAVE (lower priority)
   ```python
   class AgentContextSpanProcessor(SpanProcessor):
       def on_start(self, span: Span, parent_context=None):
           agent_uuid = _agent_uuid_context.get()
           if agent_uuid:
               span.set_attribute("agent_uuid", agent_uuid)
   ```

5. ✅ **Rich LLM attributes** - ALREADY HAVE (otel_utils.py has comprehensive attributes)

6. ✅ **Feedback endpoint** - ALREADY HAVE (router.py:1406-1519)

### Priority Assessment

**CRITICAL (Do First)**:
- ✅ Task 1.1: Add API key support to PhoenixClient
- ✅ Task 1.2: Add PHOENIX_API_KEY environment variable
- ✅ Task 1.3: Update feedback endpoint to use API key
- ✅ Task 1.4: Add auth headers to OTLP exporter
- ✅ Task 1.5: Update ConfigMap
- ✅ Task 1.6: Create Phoenix secret
- ✅ Task 1.7: Update deployment

**HIGH (Do Next)**:
- Context propagation (ContextVar + SpanProcessor)
- Enhanced LLM attribute tracking

**MEDIUM (Nice to Have)**:
- Agent UUID tracking
- OTEL collector routing (only needed if using collector, not for direct connection)

---

## 5. Implementation Checklist

### Phase 1: Authentication (Week 1)

- [ ] **Day 1**: Code Changes
  - [ ] Update PhoenixClient with api_key support (Task 1.1)
  - [ ] Update env.py with PHOENIX_API_KEY (Task 1.2)
  - [ ] Update feedback endpoint to pass API key (Task 1.3)
  - [ ] Update observability.py with auth headers (Task 1.4)

- [ ] **Day 2**: Configuration Changes
  - [ ] Update ConfigMap with Phoenix config (Task 1.5)
  - [ ] Create phoenix-secret.yaml template (Task 1.6)
  - [ ] Update app.yaml deployment (Task 1.7)

- [ ] **Day 3**: Local Testing
  - [ ] Port-forward to Phoenix
  - [ ] Create Phoenix API key
  - [ ] Test with local API key
  - [ ] Verify traces show in Phoenix
  - [ ] Verify feedback annotations work

- [ ] **Day 4**: Build & Deploy to Staging/Dev
  - [ ] Build Docker image
  - [ ] Push to registry
  - [ ] Create Phoenix API key in cluster
  - [ ] Create Kubernetes secret
  - [ ] Apply ConfigMap
  - [ ] Apply deployment
  - [ ] Restart pods

- [ ] **Day 5**: Verification & Documentation
  - [ ] Verify traces appear in Phoenix
  - [ ] Verify feedback annotations work
  - [ ] Test authentication (reject without key)
  - [ ] Update documentation
  - [ ] Create runbook

### Phase 2: Enhanced Features (Week 2) - Optional

- [ ] **Context Propagation**
  - [ ] Add ContextVar for session/user/agent
  - [ ] Create ContextSpanProcessor
  - [ ] Register processor in observability.py
  - [ ] Update ModelRunner to set context

- [ ] **Enhanced Attributes**
  - [ ] Enable prompt/completion tracking (with flag)
  - [ ] Add structured messages for Phoenix
  - [ ] Add provider-specific metadata

---

## 6. Key Files Summary

### Files to Modify

1. `percolate/clients/phoenix/client.py` - Add api_key support
2. `percolate/utils/env.py` - Add PHOENIX_API_KEY variable
3. `percolate/api/routes/chat/router.py` - Pass API key to PhoenixClient
4. `percolate/utils/observability.py` - Add auth headers to OTLP exporter
5. `.res/percolate-env-configmap.yaml` - Add Phoenix config
6. `.res/app.yaml` - Add Phoenix secret reference

### Files to Create

1. `.res/phoenix-secret.yaml` - Phoenix API key secret template

### Files to Review (for documentation)

1. `.res/README.md` - Already documents build/deploy process
2. `docs/10-observability-with-otel.md` - Update with auth steps

---

## 7. Comparison: What We Have vs What We Need

| Feature | Percolate Current | tribe/companion | Action Required |
|---------|------------------|-----------------|-----------------|
| **Feedback Endpoint** | ✅ Fully implemented | ✅ | None - already working |
| **PhoenixClient** | ⚠️ No auth | ✅ With auth | Add api_key parameter + headers |
| **OTLP Exporter** | ⚠️ No auth headers | ✅ With auth | Add authorization header |
| **Session Metadata** | ✅ Captures span IDs | ✅ | None - already working |
| **OTEL Configuration** | ✅ Enabled | ✅ | Add PHOENIX_URL/API_KEY |
| **Context Propagation** | ❌ Missing | ✅ ContextVar | Optional enhancement |
| **Rich LLM Attributes** | ✅ Comprehensive | ✅ | None - already good |
| **Environment Config** | ⚠️ Missing Phoenix vars | ✅ | Add PHOENIX_* vars |

---

## 8. Environment Variables Reference

```bash
# === Database ===
export P8_PG_HOST=localhost
export P8_PG_PORT=25432
export P8_PG_DATABASE=app
export P8_PG_USER=postgres
export P8_PG_PASSWORD=$P8_TEST_BEARER_TOKEN

# === OpenTelemetry ===
export OTEL_ENABLED=true
export OTEL_SERVICE_NAME=percolate
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc

# === Phoenix (NEW - CRITICAL) ===
export PHOENIX_ENABLED=true
export PHOENIX_URL=http://localhost:6006
export PHOENIX_API_KEY=<your-api-key>  # ⚠️ REQUIRED FOR AUTH

# === S3 ===
export S3_BUCKET_NAME=res-data-platform
export S3_DEFAULT_BUCKET=res-data-platform

# === Authentication ===
export P8_TEST_BEARER_TOKEN=<your-bearer-token>
```

---

## 9. Quick Start: Enable Phoenix Authentication

```bash
# Step 1: Create Phoenix API key (one-time setup)
kubectl port-forward -n observability svc/phoenix 6006:6006
# Open http://localhost:6006 → Settings → API Keys → Create Key

# Step 2: Create Kubernetes secret
kubectl create secret generic phoenix-api-key \
  --from-literal=PHOENIX_API_KEY=<your-key> \
  -n p8

# Step 3: Make code changes (see Phase 1 checklist)
# - Update PhoenixClient
# - Update env.py
# - Update router.py
# - Update observability.py

# Step 4: Build and deploy
cd /Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate
docker buildx build --platform linux/amd64,linux/arm64 -t percolationlabs/percolate-api:latest --push .

# Step 5: Update cluster
kubectl apply -f /Users/sirsh/code/mr_saoirse/percolate/.res/percolate-env-configmap.yaml
kubectl apply -f /Users/sirsh/code/mr_saoirse/percolate/.res/app.yaml
kubectl rollout restart deployment percolate-api -n p8

# Step 6: Verify
kubectl logs -l app=percolate-api -n p8 --tail=50 | grep -i "phoenix\|otel"
```

---

## 10. Testing Phoenix Authentication

### Test 1: Verify OTLP Traces with Auth

```bash
# Check OTLP collector logs for auth headers
kubectl logs -n observability -l app=opentelemetry-collector --tail=100 | grep authorization

# Should see traces being forwarded to Phoenix with Bearer token
```

### Test 2: Verify Feedback Annotations

```bash
# Submit feedback via API
curl -X POST https://p8.resmagic.io/chat/feedback \
  -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "test-session-123",
    "approved": true,
    "note": "Testing Phoenix annotation",
    "tags": ["test", "authentication"]
  }'

# Check Phoenix UI
kubectl port-forward -n observability svc/phoenix 6006:6006
# Open http://localhost:6006 and search for session "test-session-123"
# Should see annotation with thumbs up
```

### Test 3: Verify Authentication Works

```bash
# Test without API key (should fail)
PHOENIX_API_KEY= uvicorn percolate.api.main:app --port 5008

# Make a request - check logs
# Should see warnings about failed Phoenix annotation (401/403)

# Test with API key (should succeed)
export PHOENIX_API_KEY=<your-key>
uvicorn percolate.api.main:app --port 5008

# Make same request - check logs
# Should see "Successfully sent annotation to Phoenix"
```

---

## Appendix: tribe/companion Phoenix Setup Reference

For comparison, here's how tribe/companion configured Phoenix with authentication:

### OTEL Collector Configuration

```yaml
exporters:
  otlp/phoenix:
    endpoint: phoenix-svc:4317
    tls:
      insecure: true
    headers:
      authorization: Bearer ${env:PHOENIX_API_KEY}

env:
  - name: PHOENIX_API_KEY
    valueFrom:
      secretKeyRef:
        name: phoenix-secret
        key: PHOENIX_API_KEY
```

### Phoenix Deployment

```yaml
env:
  - name: PHOENIX_ENABLE_AUTH
    value: "true"
  - name: PHOENIX_API_KEY
    valueFrom:
      secretKeyRef:
        name: phoenix-secret
        key: PHOENIX_API_KEY
```

### PhoenixClient Usage

```python
from tribe_ai.clients.phoenix import PhoenixClient

client = PhoenixClient(
    base_url=global_settings.phoenix.url,
    api_key=global_settings.phoenix.api_key.get_secret_value()
)

await client.send_feedback_annotation(
    trace_id=message.trace_id,
    span_id=message.generation_metadata.span_id,
    message_uuid=str(feedback_dto.message_uuid),
    feedback_type=feedback_dto.type.value,
    user_uuid=str(feedback_dto.user_uuid),
    rating=feedback_dto.rating.value,
    feedback_text=feedback_dto.feedback,
)
```

---

## Summary

**Main Differences from Original Plan**:
1. ✅ Feedback endpoint already exists - no need to create
2. ✅ PhoenixClient already exists - just needs auth support
3. ✅ OTEL configuration already exists - just needs auth headers
4. ✅ Session metadata capture already working
5. ❌ Only missing piece is **authentication** in PhoenixClient and OTLP exporter

**Estimated Time**:
- **Critical Auth Changes**: 1-2 days
- **Testing & Deployment**: 1-2 days
- **Total**: 2-4 days vs original estimate of 4 weeks

**Next Steps**:
1. Review this plan
2. Create Phoenix API key in observability namespace
3. Implement Phase 1 authentication changes
4. Test locally
5. Deploy to cluster
6. Verify traces and feedback work with authentication
