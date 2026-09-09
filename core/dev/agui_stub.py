"""A stub that speaks the runtime's AG-UI event contract, so the UI's streaming
path can be exercised without an LLM or a cluster.

    python3 dev/agui_stub.py 8099 fast     # a whole turn in a few hundred ms
    python3 dev/agui_stub.py 8098 hold     # stops mid-turn, one tool running
    P8_UI_CORE_URL=http://127.0.0.1:8099 p8 ui serve

It exists because the chat screen's progress rendering is driven entirely by
these events, and the dev stack runs no agent runtime -- so without it the only
way to see a turn render is to have an LLM, a runtime and a cluster, and the
rendering is the part that has nothing to do with any of them. It found a real
bug the first time it ran: the UI re-read the transcript after the stream and
blanked the answer, because this writes no rows.

NOT the agent runtime and not pretending to be: it emits the exact event types
from percolate_core/agentic/contracts/protocol.py and nothing else, which is the
only thing the browser is being tested against.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ANSWER = """Four steps, and **none of them need code**.

## Why a matrix

`fetch` is a `matrix` over the ticker list, so the fan-out is the database's job
rather than a loop in a worker — and the children are created in the transaction
that completes the parent, so there is no window where the parent is done and
the children do not exist.

1. **`batch_size: 25`** keeps a hundred one-row children from costing a hundred
   claims for a four-millisecond write.
2. **The 429 goes on `rate_key`**, not into retry logic.

```yaml
- id: fetch
  matrix: {rows: '{{steps.tickers.result}}', batch_size: 25}
  rate_key: 'vendor:sec-api'
```

> `terminal=true` on a 429 does not retry at all.
"""

def sse(w, kind, **fields):
    fields["type"] = kind
    w.write(f"event: {kind}\ndata: {json.dumps(fields)}\n\n".encode())
    w.flush()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "authorization,content-type,accept")
        self.send_header("Access-Control-Allow-Methods", "POST,GET,OPTIONS")

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.send_header("Content-Length", "0"); self.end_headers()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self._cors(); self.end_headers()

        class Chunked:
            def __init__(self, raw): self.raw = raw
            def write(self, b): self.raw.write(b"%x\r\n" % len(b) + b + b"\r\n")
            def flush(self): self.raw.flush()
        w = Chunked(self.wfile)

        # Two modes, because headless Chrome's --virtual-time-budget is VIRTUAL:
        # a page with a 100ms timer burns the budget almost instantly while the
        # stub's real sleeps have barely started. So "hold" emits the progress
        # state and stops, and "fast" runs the whole turn inside a few hundred
        # real milliseconds. Neither changes what is emitted, only when.
        mode = sys.argv[2] if len(sys.argv) > 2 else "fast"
        gap = 0.02 if mode == "fast" else 0.0
        run = "01a08600-0000-7000-8000-000000000001"
        sse(w, "RUN_STARTED", run_id=run, agent_name="workflow-author")
        sse(w, "TOOL_CALL_START", run_id=run, tool_call_id="t1", tool_name="aiq.schema")
        time.sleep(gap)
        sse(w, "TOOL_CALL_END", run_id=run, tool_call_id="t1", is_error=False)
        sse(w, "TOOL_CALL_START", run_id=run, tool_call_id="t2",
            tool_name="risk-summariser", child_run_id="01a08600-0000-7000-8000-000000000002")
        if mode == "hold":
            time.sleep(120)            # a turn caught mid-flight, and held there
            return
        time.sleep(gap)
        sse(w, "TOOL_CALL_END", run_id=run, tool_call_id="t2", is_error=False)
        sse(w, "TEXT_MESSAGE_START", run_id=run, message_id="m1")
        for i in range(0, len(ANSWER), 24):
            sse(w, "TEXT_MESSAGE_CONTENT", run_id=run, message_id="m1", delta=ANSWER[i:i + 24])
            time.sleep(0.004)
        sse(w, "TEXT_MESSAGE_END", run_id=run, message_id="m1")
        sse(w, "RUN_FINISHED", run_id=run, status="succeeded")
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()

    def log_message(self, *a): pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
