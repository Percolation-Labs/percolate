#!/bin/bash
# Every block of "Percolate for Zep users", in order, from an empty directory, against a real model and the reader's
# own Claude:
#
#     OPENAI_API_KEY=... dev/examples/zep-memory/run.sh [workdir]
#
# blocks/00-setup.sh is the article's setup block: it starts get-percolate's compose stack at the release tag it names, installs
# the CLI and signs in. PROJECT renames its compose project and directory, PORT_BASE moves its seven ports to
# PORT_BASE..PORT_BASE+6, and IMG pins the database image, so a run can sit beside other stacks; otherwise it runs as
# written. The SQL blocks that need no model are asserted by dev/tests/query/21-zep-quickstart.sql. This runs the rest:
# Ana's assistant's turns (gpt-4o-mini, then gpt-4o), the reading her agent does over MCP, and blocks/08-claude.sh,
# where `claude -p` (Claude Code, on PATH and signed in) decides the judgements dream queued.
#
# Each block's input and output go to <workdir>/captures. The key goes into the stack's .env only, and the script fails
# if it appears in a capture. Tear down with `docker compose -p $PROJECT down -v` from <workdir>/$PROJECT.
set -u
B=$(cd "$(dirname "$0")" && pwd)/blocks
W=${1:-$(mktemp -d)}; CAP=$W/captures
PROJECT=${PROJECT:-zep-tour}
: "${OPENAI_API_KEY:?set OPENAI_API_KEY}"
command -v claude > /dev/null || { echo "blocks/08-claude.sh needs Claude Code (claude) on PATH"; exit 1; }
# Run from inside a Claude Code session, the nested `claude -p` would refuse to start.
unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_MESSAGING_SOCKET \
      CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT
# A reader's Claude starts with no hooks of this machine's user's: read only project settings, of which there are none.
claude() { command claude --setting-sources project "$@"; }
mkdir -p $W $CAP; cd $W
OK=$OPENAI_API_KEY
umask 077
SETUP=$CAP/.setup.sh
sed "s/zep-tour/$PROJECT/g" $B/00-setup.sh > $SETUP
if [ -n "${PORT_BASE:-}" ]; then
  i=0
  for v in PG REST AGENT CONTENT MINIO MINIO_CONSOLE QUERY_MCP; do
    sed -i.bak "s/^P8_${v}_PORT=.*/P8_${v}_PORT=$((PORT_BASE + i))/" $SETUP; i=$((i + 1))
  done
fi
[ -n "${IMG:-}" ] && awk -v img="$IMG" '{print} /^COMPOSE_PROJECT_NAME=/{print "P8_DB_IMAGE=" img}' $SETUP > $SETUP.new && mv $SETUP.new $SETUP
rm -f $SETUP.bak
fail=0
{ sed 's/^/$ /' $B/00-setup.sh; . $SETUP < /dev/null 2>&1; } > $CAP/00-setup.txt
rm -f $SETUP
[ -n "${TOKEN:-}" ] || { echo "FAIL 00-setup.sh"; exit 1; }
echo "done 00-setup.sh"
for f in $(ls $B | sort | grep -v '^00-setup'); do
  out=$CAP/${f%.*}.txt
  case $f in
    *.sh)  { sed 's/^/$ /' $B/$f; . $B/$f < /dev/null 2>&1; } > $out
           grep -q '^Error' $out && { echo "FAIL $f"; fail=1; } ;;
    *.sql) { sed 's/^/=# /' $B/$f; psql "$P8_DSN" -X -v ON_ERROR_STOP=1 -f $B/$f 2>&1; } > $out
           grep -q '^psql:.*ERROR' $out && { echo "FAIL $f"; fail=1; } ;;
  esac
  echo "done $f"
done
if grep -rlF -e "$OK" $CAP; then echo "the key reached a capture"; fail=1; fi
sed -i.bak 's/^OPENAI_API_KEY=.*/OPENAI_API_KEY=removed-after-run/' .env && rm -f .env.bak
echo fail=$fail
exit $fail
