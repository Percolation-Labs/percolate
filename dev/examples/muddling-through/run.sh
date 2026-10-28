#!/bin/bash
# The Muddling Through walkthrough's setup block, from an empty directory, on the published images (REM-1203):
#
#     IMG=percolationlabs/percolate-postgres:19-0.2.32 CORE='percolate-core[sample]>=0.2.12' \
#         dev/examples/muddling-through/run.sh [workdir]
#
# It starts a stack and runs blocks/*.sh in order; 01-setup.sh downloads BEAM from Hugging Face, loads the two samples and
# indexes both conversations. No key
# and no bill: bge-small runs in the stack's worker. The project is its own (muddling-through), so `down -v` touches
# nothing else. Each block's output lands in <workdir>/captures. The steps that walk come after this, one per card.
# The expected files assume these two samples are all the stack holds: a walk's search is not yet scoped to its own
# channel, so other loaded sources change the order it reads in (REM-1214).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(mktemp -d)}; CAP=$W/captures
IMG=${IMG:-percolationlabs/percolate-postgres:19-0.2.32}
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
# From empty means from empty: a stack left by an earlier run would add its rows to this one's, and every count
# doubles. The project is this walkthrough's own, so `down -v` removes nothing else.
docker compose down -v --remove-orphans > /dev/null 2>&1
docker compose up -d --wait > $CAP/00-stack.txt 2>&1 || { echo stack failed; exit 1; }
# No pip cache: a core installed from a local path keeps its version number between builds, and a cached wheel of
# that version would be installed in place of the tree it names (cory, 27 Oct).
python3 -m venv .venv > /dev/null && . .venv/bin/activate && PIP_NO_CACHE_DIR=1 pip -q install "$CORE" > /dev/null 2>&1
export P8_ADMIN_DSN=postgres://p8:p8@localhost:5801/percolate P8_DSN=postgres://p8:p8@localhost:5801/percolate
export P8_JWT_SECRET=change-me-a-long-random-string-at-least-32-chars
# A signed-in reader: the walk embeds its question through the Content Server's /embed, which needs a token.
psql "$P8_ADMIN_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')" > /dev/null
export TOKEN=$(percolate auth token --email me@example.com)
cp -R "$HERE/samples" "$HERE/build" .

# Each block runs in order from this directory, as a reader pastes it; its output is captures/<block>.txt.
fail=0
for f in $(ls "$HERE/blocks" | sort); do
  out=$CAP/${f%.*}.txt
  bash -eu "$HERE/blocks/$f" > "$out" 2>&1 || { echo "FAILED $f"; tail -20 "$out"; fail=1; break; }
  echo "ok $f"
done
[ $fail = 0 ] || exit 1

# What the article says the setup leaves: two conversations and a world, each with the links a walk follows.
S=$CAP/01-setup.txt
grep -q '"documents": 1101' $S && grep -q '"documents": 1058' $S && grep -q 'walk_tagged  *| *45156' $S \
  || { echo "setup did not leave what the article says"; cat $S; exit 1; }
# Step 1: by read 500 the walk has 21 of the 27, and search's own top 500 holds 16 (REM-1204).
grep -Eq '^ +10 \| +500 \| +21 \| +16 \| +27$' $CAP/10-walk-vs-search.txt \
  || { echo "step 1 did not find what the article says"; cat $CAP/10-walk-vs-search.txt; exit 1; }
# Step 5, on both clocks (REM-1213): known now, the budget now is the raised one and at 00:11:20 the earlier one;
# known after the first landing, the budget now is still the earlier one, which is the memory being wrong.
grep -Eq '^ now +\| now +\| .*\$160' $CAP/60-time.txt && grep -Eq '^ now +\| 2024-08-12 00:11:20 \| .*\$150' $CAP/60-time.txt \
  && grep -Eq '^ after the first landing \| now +\| .*\$150' $CAP/60-time.txt \
  || { echo "step 5 did not answer as the article says"; cat $CAP/60-time.txt; exit 1; }
# A block with an expected file prints exactly that: the article quotes it.
# Every file is compared before failing, so one difference cannot hide another.
differ=0
for e in "$HERE"/expected/*.txt; do
  [ -e "$e" ] || continue
  diff -q "$e" "$CAP/$(basename "$e")" > /dev/null \
    || { echo "$(basename "$e" .txt) differs from what the article quotes"; diff "$e" "$CAP/$(basename "$e")"; differ=1; }
done
[ $differ = 0 ] || exit 1
echo "all blocks ok: $W"
