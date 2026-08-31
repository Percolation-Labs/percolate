#!/usr/bin/env bash
# The two processes the runtime binds to in this experiment, alongside the
# pg19 stack (experiments/pg19-stack/docker-compose.yml, started separately).
#
#   1. PostgREST over the `agentic` schema, on :3001 -- the OpenAPI tool
#      server. It is deliberately a *separate* instance from pg19-stack's own
#      PostgREST: this one exists to be bound as a tool, and pointing an agent
#      at "the CRUD surface of the very schema it writes its own messages to"
#      is the most honest test there is of "tools are just CRUD services".
#   2. The agent gateway on :8765 -- this runtime's agents as an MCP server,
#      which is what makes delegation an ordinary tool_servers reference
#      (brief.md §5.1 item 3).
#
# Usage: ./dev/stack.sh up | down
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NET=${P8_PG_NETWORK:-pg19-stack_default}
DBHOST=${P8_PG_HOST:-p8-agentic-pg}
DBNAME=${P8_PG_DB:-p8agentic}
SECRET=${P8_JWT_SECRET:-experiment-only-jwt-secret-not-for-real-use-0123456789}

case "${1:-up}" in
up)
  docker rm -f p8-agentic-postgrest >/dev/null 2>&1 || true
  docker run -d --name p8-agentic-postgrest --network "$NET" -p 3001:3000 \
    -e PGRST_DB_URI="postgres://authenticator:authpass@$DBHOST:5432/$DBNAME" \
    -e PGRST_DB_SCHEMAS="agentic,demo" \
    -e PGRST_DB_ANON_ROLE=web_anon \
    -e PGRST_JWT_SECRET="$SECRET" \
    postgrest/postgrest:v12.2.8 >/dev/null
  echo "==> postgrest (agentic schema) on http://localhost:3001"

  # A second PostgREST, over the `demo` schema only, standing in for a
  # retrieval service: a separate deployment is the honest model (a tool server
  # is an independently deployed microservice, brief.md §5.2) and it is what
  # lets `p8-rag` be registered with emits_citations = true while the CRUD
  # server is not.
  docker rm -f p8-demo-rag >/dev/null 2>&1 || true
  docker run -d --name p8-demo-rag --network "$NET" -p 3002:3000 \
    -e PGRST_DB_URI="postgres://authenticator:authpass@$DBHOST:5432/$DBNAME" \
    -e PGRST_DB_SCHEMAS="demo" \
    -e PGRST_DB_ANON_ROLE=web_anon \
    -e PGRST_JWT_SECRET="$SECRET" \
    postgrest/postgrest:v12.2.8 >/dev/null
  echo "==> postgrest (demo retrieval) on http://localhost:3002"

  pkill -f "percolate_core.cli gateway" 2>/dev/null || true
  # The gateway dispatches delegated calls of its own (a sub-agent that
  # delegates further), so it needs the same credentials any other caller
  # does. That an `env:` credential_ref has to be present in *every* process
  # that might dispatch is precisely the limitation brief.md §9 flags: it is a
  # placeholder for a secrets mechanism, not one.
  export P8_REST_TOKEN=$(python3 "$HERE/../../pg19-stack/mint_jwt.py" \
      "${P8_USER_ID:-aaaaaaaa-0000-0000-0000-000000000001}")
  # P8_DEFAULT_MODEL is inherited: set it to `test` for a no-credentials run
  # (pydantic-ai's TestModel drives delegated runs through the whole real path
  # -- MCP round trip, child runs row, rows, events -- without an LLM), or to a
  # real model id to run delegated agents against a live provider.
  (cd "$HERE/.." && P8_JWT_SECRET="$SECRET" \
     P8_DATABASE_URL="${P8_DATABASE_URL:-postgresql://p8:p8@localhost:5500/p8agentic}" \
     P8_REST_TOKEN="$P8_REST_TOKEN" \
     P8_DEFAULT_MODEL="${P8_DEFAULT_MODEL:-test}" \
     OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
     uv run python -m percolate_core.cli gateway >/tmp/p8-gateway.log 2>&1 &)
  sleep 4
  echo "==> agent gateway on http://127.0.0.1:8765/mcp (log: /tmp/p8-gateway.log)"
  ;;
down)
  docker rm -f p8-agentic-postgrest >/dev/null 2>&1 || true
  pkill -f "percolate_core.cli gateway" 2>/dev/null || true
  # The gateway dispatches delegated calls of its own (a sub-agent that
  # delegates further), so it needs the same credentials any other caller
  # does. That an `env:` credential_ref has to be present in *every* process
  # that might dispatch is precisely the limitation brief.md §9 flags: it is a
  # placeholder for a secrets mechanism, not one.
  export P8_REST_TOKEN=$(python3 "$HERE/../../pg19-stack/mint_jwt.py" \
      "${P8_USER_ID:-aaaaaaaa-0000-0000-0000-000000000001}")
  echo "==> stopped"
  ;;
*)
  echo "usage: $0 up|down" >&2; exit 2 ;;
esac
