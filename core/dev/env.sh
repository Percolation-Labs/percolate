# source dev/env.sh -- everything the CLI and scripts need, in one place.
#
# Order matters: P8_ENV_FILE, if set, is read FIRST (where the LLM key lives on
# this machine, since a key belongs in exactly one file), then this
# experiment's own values are set, so ours win. A key named P8_OPENAI_API_KEY
# is copied to OPENAI_API_KEY, which pydantic-ai reads.
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -n "${P8_ENV_FILE:-}" ] && [ -f "$P8_ENV_FILE" ]; then
  set -a; . "$P8_ENV_FILE"; set +a
fi
[ -n "${P8_OPENAI_API_KEY:-}" ] && export OPENAI_API_KEY="$P8_OPENAI_API_KEY"

# This experiment's own Postgres (dev/db.sh) -- a separate cluster from
# pg19-stack's, because cluster-level roles are shared and that stack's
# --fresh drops them out from under anything else running.
export P8_DATABASE_URL="postgresql://p8:p8@localhost:5500/p8agentic"
export P8_USER_ID="aaaaaaaa-0000-0000-0000-000000000001"
export P8_JWT_SECRET="experiment-only-jwt-secret-not-for-real-use-0123456789"
export P8_REST_TOKEN="$(python3 "$_here/mint_jwt.py" "$P8_USER_ID")"
unset _here
