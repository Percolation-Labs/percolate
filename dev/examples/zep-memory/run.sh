#!/bin/bash
# Every block of "Percolate for Zep users", in order, from an empty directory, on part one's stack (the LangGraph
# tour), against a real model:
#
#     OPENAI_API_KEY=... IMG=percolationlabs/percolate-postgres:19-0.2.27 dev/examples/zep-memory/run.sh [workdir]
#
# The SQL blocks that need no model are asserted by dev/tests/query/21-zep-quickstart.sql. This runs the rest too:
# Ana's assistant's turns, the only model calls, and the reading and judging her own agent does over MCP. Each block's input and output
# land in <workdir>/captures. The key goes into the stack's .env only, and the script fails if it appears in a
# capture. The project is its own (zep-memory), so `down -v` touches nothing else.
#
# UPGRADE=<percolate--A--B.sql> runs an image that predates a release: the script is copied into the database
# container and applied as app_owner before any block, which is how this ran on main before 0.2.24 was published.
set -u
B=$(cd "$(dirname "$0")" && pwd)/blocks
W=${1:-$(mktemp -d)}; CAP=$W/captures
IMG=${IMG:-percolationlabs/percolate-postgres:19-0.2.27}
: "${OPENAI_API_KEY:?set OPENAI_API_KEY}"
mkdir -p $W $CAP; cd $W
OK=$OPENAI_API_KEY
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml -o docker-compose.yml
umask 077
cat > .env <<ENV
COMPOSE_PROJECT_NAME=zep-memory
P8_DB_IMAGE=$IMG
P8_PG_PORT=5791
P8_REST_PORT=5792
P8_AGENT_PORT=5793
P8_CONTENT_PORT=5794
P8_MINIO_PORT=5795
P8_MINIO_CONSOLE_PORT=5796
P8_QUERY_MCP_PORT=5797
OPENAI_API_KEY=$OK
ENV
docker compose up -d --wait > $CAP/00-stack.txt 2>&1 || { echo stack failed; exit 1; }
if [ -n "${UPGRADE:-}" ]; then
  D=$(docker compose exec -T db pg_config --sharedir)/extension
  docker compose cp "$UPGRADE" db:$D/ > /dev/null
  to=$(basename "$UPGRADE" .sql); to=${to##*--}
  docker compose exec -T db psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q \
    -c "set role app_owner" -c "alter extension percolate update to '$to'" > $CAP/00-upgrade.txt 2>&1 \
    || { echo upgrade failed; exit 1; }
fi
python3 -m venv .venv > /dev/null && . .venv/bin/activate && pip -q install 'percolate-core[sample,agent]>=0.2.5' > /dev/null 2>&1
set -a; . ./.env; set +a
export PAGER=cat
export P8_DSN=postgres://p8:p8@localhost:$P8_PG_PORT/percolate
export P8_ADMIN_DSN=$P8_DSN
export P8_JWT_SECRET=change-me-a-long-random-string-at-least-32-chars
REST=http://localhost:$P8_REST_PORT
AGENT=http://localhost:$P8_AGENT_PORT
psql "$P8_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')" > /dev/null
export P8_USER_ID=$(psql "$P8_DSN" -Atc "select id from rbac.users where email = 'me@example.com'")
export TOKEN=$(percolate auth token --email me@example.com)
show() {
  for i in $(seq 150); do
    [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$1'")" != running ] && break
    sleep 2
  done
  psql "$P8_DSN" -c "select status, compensation_state from workflow.runs where id = '$1'" \
    -c "select step_key, status, left(output->>'result', 60) as result,
               left(coalesce(error->>'error', error::text), 120) as error
        from workflow.tasks where run_id = '$1'
        order by completed_at nulls last, step_key"
}
fail=0
for f in $(ls $B | sort); do
  out=$CAP/${f%.*}.txt
  case $f in
    *.sh)  { sed 's/^/$ /' $B/$f; . $B/$f 2>&1; } > $out ;;
    *.sql) { sed 's/^/=# /' $B/$f; psql "$P8_DSN" -X -v ON_ERROR_STOP=1 -f $B/$f 2>&1; } > $out
           grep -q '^psql:.*ERROR' $out && { echo "FAIL $f"; fail=1; } ;;
  esac
  echo "done $f"
done
if grep -rlF -e "$OK" $CAP; then echo "the key reached a capture"; fail=1; fi
sed -i.bak 's/^OPENAI_API_KEY=.*/OPENAI_API_KEY=removed-after-run/' .env && rm -f .env.bak
echo fail=$fail
exit $fail
