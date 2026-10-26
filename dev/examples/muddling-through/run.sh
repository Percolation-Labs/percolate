#!/bin/bash
# The Muddling Through walkthrough's setup block, from an empty directory, on the published images (REM-1203):
#
#     IMG=percolationlabs/percolate-postgres:19-0.2.31 CORE='percolate-core[sample]>=0.2.12' \
#         dev/examples/muddling-through/run.sh [workdir]
#
# It starts a stack, loads the two samples, waits for the worker to embed BEAM, and indexes both conversations. No key
# and no bill: bge-small runs in the stack's worker. The project is its own (muddling-through), so `down -v` touches
# nothing else. Each block's output lands in <workdir>/captures. The steps that walk come after this, one per card.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(mktemp -d)}; CAP=$W/captures
IMG=${IMG:-percolationlabs/percolate-postgres:19-0.2.31}
CORE=${CORE:-percolate-core[sample]>=0.2.12}
mkdir -p $W $CAP; cd $W
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml -o docker-compose.yml
cat > .env <<ENV
COMPOSE_PROJECT_NAME=muddling-through
P8_DB_IMAGE=$IMG
P8_PG_PORT=5801
P8_REST_PORT=5802
P8_AGENT_PORT=5803
P8_CONTENT_PORT=5804
P8_MINIO_PORT=5805
P8_MINIO_CONSOLE_PORT=5806
P8_QUERY_MCP_PORT=5807
ENV
docker compose up -d --wait > $CAP/00-stack.txt 2>&1 || { echo stack failed; exit 1; }
python3 -m venv .venv > /dev/null && . .venv/bin/activate && pip -q install "$CORE" > /dev/null 2>&1
export P8_ADMIN_DSN=postgres://p8:p8@localhost:5801/percolate P8_DSN=postgres://p8:p8@localhost:5801/percolate
export P8_JWT_SECRET=change-me-a-long-random-string-at-least-32-chars
# A signed-in reader: the walk embeds its question through the Content Server's /embed, which needs a token.
psql "$P8_ADMIN_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')" > /dev/null
export TOKEN=$(percolate auth token --email me@example.com)
cp -R "$HERE/samples" .

# --- the setup block, as the article prints it ---------------------------------------------------------------------
{
percolate sample load samples/beam
percolate sample load samples/walk-0
} > $CAP/01-load.txt 2>&1 || { cat $CAP/01-load.txt; exit 1; }

# The worker embeds 2,159 exchanges in the background; index once it has.
for i in $(seq 360); do
  left=$(psql "$P8_ADMIN_DSN" -Atc "select count(*) from workflow.runs r join workflow.definitions d
                                     on d.id = r.workflow_def_id where d.name = 'embed_text' and r.status = 'running'")
  [ "$left" = 0 ] && break
  sleep 10
done

{
percolate walk index --source beam-1m22
percolate walk index --source beam-1m35
} > $CAP/02-index.txt 2>&1 || { cat $CAP/02-index.txt; exit 1; }
# ---------------------------------------------------------------------------------------------------------------------

# What the article says the setup leaves: two conversations and a world, each with the links a walk follows.
psql "$P8_ADMIN_DSN" -c "select relation, count(*) from aiq.edges_current where relation like 'walk_%'
                          group by 1 order by 1" > $CAP/03-links.txt
cat $CAP/02-index.txt $CAP/03-links.txt
grep -q '"documents": 1101' $CAP/02-index.txt && grep -q '"documents": 1058' $CAP/02-index.txt \
  && grep -q 'walk_tagged  *| *45156' $CAP/03-links.txt || { echo "setup did not leave what the article says"; exit 1; }
echo "setup ok: $W"
