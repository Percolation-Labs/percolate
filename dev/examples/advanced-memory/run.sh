#!/bin/bash
# Every block of "Advanced Percolate Memory", in order, from an empty directory, with the reader's own Claude:
#
#     dev/examples/advanced-memory/run.sh [workdir]
#
# blocks/00-setup.sh is the article's setup block: it starts get-percolate's compose stack at the release tag it
# names, installs the CLI and signs in. PROJECT renames its compose project and directory, PORT_BASE moves its seven
# ports to PORT_BASE..PORT_BASE+6, and IMG pins the database image, so a run can sit beside other stacks; otherwise it
# runs as written. Embeddings are bge-small-en-v1.5, which the worker runs itself, so no block needs a key.
#
# The SQL blocks go to one psql session, each pasted whole, as a reader pastes them (psqlpaste.py says why). The SQL
# blocks that need no worker or model are asserted by dev/tests/query/20-advanced-memory-article.sql. This runs the
# rest: the embedding workflows, SEARCH and SEMANTIC in a workflow, and blocks/02-claude.sh and 09-links.sh, where
# `claude -p` (Claude Code, on PATH and signed in) decides the alias and chooses which question each fact bears on.
#
# Each block's input and output go to <workdir>/captures. Tear down with `docker compose -p $PROJECT down -v` from
# <workdir>/$PROJECT.
set -u
B=$(cd "$(dirname "$0")" && pwd)/blocks
W=${1:-$(mktemp -d)}; CAP=$W/captures
PROJECT=${PROJECT:-advanced-tour}
command -v claude > /dev/null || { echo "blocks/02-claude.sh needs Claude Code (claude) on PATH"; exit 1; }
# Run from inside a Claude Code session, the nested `claude -p` would refuse to start.
unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_MESSAGING_SOCKET \
      CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT
# A reader's Claude starts with no hooks of this machine's user's: read only project settings, of which there are none.
claude() { command claude --setting-sources project "$@"; }
mkdir -p $W $CAP; cd $W
umask 077
SETUP=$CAP/.setup.sh
sed "s/advanced-tour/$PROJECT/g" $B/00-setup.sh > $SETUP
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
# The reader's second terminal: one psql session for every SQL block.
mkfifo $W/cmd $W/ack
python3 -I "$(dirname "$B")/psqlpaste.py" "$P8_DSN" $W/cmd $W/ack &
exec 3> $W/cmd 4< $W/ack
for f in $(ls $B | sort | grep -v '^00-setup'); do
  out=$CAP/${f%.*}.txt
  case $f in
    *.sh)  { sed 's/^/$ /' $B/$f; . $B/$f < /dev/null 2>&1; } > $out
           grep -q -e '^Error' -e 'ERROR:' -e 'failed:' $out && { echo "FAIL $f"; fail=1; } ;;
    *.sql) echo "$B/$f $out" >&3
           read -r verdict <&4
           [ "$verdict" = ok ] || { echo "FAIL $f"; fail=1; } ;;
  esac
  echo "done $f"
done
exec 3>&-; wait
echo fail=$fail
exit $fail
