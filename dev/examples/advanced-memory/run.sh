#!/bin/bash
# Every block of "Advanced Percolate memory and semantic iteration", in order, from an empty directory, on part one's
# stack (the LangGraph tour), against a real decider. Embeddings are bge-small, which the worker runs itself, so the
# only key is Jev's:
#
#     JEV_API_KEY=... IMG=percolationlabs/percolate-postgres:19-0.2.35 dev/examples/advanced-memory/run.sh [workdir]
#
# The SQL blocks are dev/tests/query/20-advanced-memory-article.sql's, which asserts the ones that need no model.
# This runs the rest too: linking facts to questions with Jev, embedding notes, SEARCH and SEMANTIC in a workflow.
# Each block's input and output land in <workdir>/captures. The keys go into the stack's .env and worker.env only; the script
# fails if either appears in a capture. The project is its own (advanced-memory), so `down -v` touches nothing else.
set -u
B=$(cd "$(dirname "$0")" && pwd)/blocks
W=${1:-$(mktemp -d)}; CAP=$W/captures
IMG=${IMG:-percolationlabs/percolate-postgres:19-0.2.35}
: "${JEV_API_KEY:?set JEV_API_KEY}"
mkdir -p $W $CAP; cd $W
OK=${OPENAI_API_KEY:-}; JK=$JEV_API_KEY
# part one's stack block, with the documented deviations: image, project name, ports
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml -o docker-compose.yml
umask 077
cat > .env <<ENV
COMPOSE_PROJECT_NAME=advanced-memory
P8_DB_IMAGE=$IMG
P8_PG_PORT=5781
P8_REST_PORT=5782
P8_AGENT_PORT=5783
P8_CONTENT_PORT=5784
P8_MINIO_PORT=5785
P8_MINIO_CONSOLE_PORT=5786
P8_QUERY_MCP_PORT=5787
ENV
[ -n "$OK" ] && echo "OPENAI_API_KEY=$OK" >> .env
docker compose up -d --wait > $CAP/00-stack.txt 2>&1 || { echo stack failed; exit 1; }
python3 -m venv .venv > /dev/null && . .venv/bin/activate && pip -q install 'percolate-core[sample,agent]==0.2.16' > /dev/null 2>&1
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
start() {
  curl -s $REST/rpc/start_workflow \
    -H 'Content-Profile: workflow' -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"p_name\": \"$1\", \"p_input\": $2}" | jq -r .
}
show() {
  for i in $(seq 30); do
    [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$1'")" != running ] && break
    sleep 2
  done
  psql "$P8_DSN" -c "select status, compensation_state from workflow.runs where id = '$1'" \
    -c "select step_key, status, left(output->>'result', 60) as result,
               left(coalesce(error->>'error', error::text), 120) as error
        from workflow.tasks where run_id = '$1'
        order by completed_at nulls last, step_key"
}
# One psql session for every SQL block, each pasted whole, as a reader pastes it (psqlpaste.py says why).
mkfifo $W/cmd $W/ack
python3 -I "$(dirname "$B")/psqlpaste.py" "$P8_DSN" $W/cmd $W/ack &
exec 3> $W/cmd 4< $W/ack
waiting() {
  for i in $(seq 90); do
    s=$(psql "$P8_DSN" -Atc "select status from workflow.tasks where run_id = '$1' and step_key = '$2'")
    case $s in waiting_external|succeeded|skipped|failed|cancelled) break ;; esac
    sleep 2
  done
  echo "$s"
}
fail=0
for f in $(ls $B | grep -v '^00-' | sort); do
  out=$CAP/${f%.*}.txt
  case $f in
    01b-connect.sh)
      # Connecting the reader's own Claude edits their client's config, so the run does not; 03-claim.sh and 03b-decide.sh make the
      # same MCP calls their Claude makes, as the same signed-in person.
      { sed 's/^/$ /' $B/$f; echo "(not run here: it connects the reader's own Claude)"; } > $out ;;
    *.sh)
      # the one documented deviation in a shell block: the real Jev key
      sed -e "s#your-jev-key#$JK#" $B/$f > $W/blk.sh
      { sed 's/^/$ /' $B/$f; . $W/blk.sh 2>&1; } > $out
      rm -f $W/blk.sh
      [ "$f" = 01-jev.sh ] && sleep 5 ;;
    *.sql)
      echo "$B/$f $out" >&3
      read -r verdict <&4
      [ "$verdict" = ok ] || { echo "FAIL $f"; fail=1; } ;;
  esac
  echo "done $f"
done
exec 3>&-; wait
if grep -rlF -e "$JK" ${OK:+-e "$OK"} $CAP; then echo "a key reached a capture"; fail=1; fi
echo fail=$fail
exit $fail
