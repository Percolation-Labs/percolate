#!/usr/bin/env bash
# Drive ONE agent turn against the database under test, and record what
# happened in a table the .sql file that asked for it can read.
#
# Called by dev/tests/run.sh for a file carrying `-- drives: agent-turn`. Not
# meant to be run by hand, though it can be:
#
#     CONTAINER=p8-ci DB=p8ci dev/tests/drive/agent-turn.sh
#
# WHY A DRIVER AT ALL. Every other file in this suite is .sql run by psql, and
# `-- loads:` already exists for the one other thing a test cannot do for
# itself. A turn is HTTP: a prompt goes to a process, AG-UI events come back,
# and rows appear. Postgres cannot make that call, so the shell makes it and
# leaves the result where SQL can assert on it -- the same division `-- loads:`
# uses, and the reason this is thirty lines of driver rather than an http
# extension in the database.
#
# THE AGENT RUNS IN THE DATABASE CONTAINER'S NETWORK NAMESPACE
# (`--network container:$CONTAINER`), which is the whole reason this needs no
# compose stack, no published port and no host networking. The runtime reaches
# Postgres on 127.0.0.1:5432 and this script reaches the runtime on
# 127.0.0.1:8080, both from inside that namespace. A gate that required the
# compose stack would be a gate CI cannot run, and `dev/ci-database.sh` builds
# a bare container on purpose.
set -euo pipefail
cd "$(dirname "$0")/../../.."

CONTAINER="${CONTAINER:-p8-dev-db}"
DB="${DB:-p8dev}"
AGENT="${AGENT_CONTAINER:-$CONTAINER-agent}"
# Named for the container it grades, like dev/upgrade-with-data.sh's UPGC and
# for the same reason: three sessions run this at once on this machine.
SECRET="${P8_JWT_SECRET:-experiment-only-jwt-secret-not-for-real-use-0123456789}"
AGENT_NAME="${P8_TEST_AGENT:-turn-gate-probe}"
CALLER_EMAIL="${P8_TEST_CALLER:-turn-gate@dev.invalid}"
# The provider this probe names. It is never reached without a key, which is
# the point -- the assertion permits exactly that one failure.
AGENT_MODEL="${P8_TEST_MODEL:-openai:gpt-4o-mini}"

# THE IMAGE PIN IS READ, not written here. `dev/docker-compose.yml` is where
# this repository decides which percolate-core it runs; a second copy in this
# file would be the class of defect REM-56 is about, in the file whose job is
# catching regressions.
IMAGE=$(sed -n 's|^ *image: *\(percolationlabs/percolate-core:[0-9][0-9.]*\).*|\1|p' \
        dev/docker-compose.yml | head -1)
# With the &core-image anchor it is written once, in the anchor, under a
# ${P8_CORE_IMAGE:-...} default -- read that shape too rather than only the
# plain one, so this keeps working either side of that change.
[ -n "$IMAGE" ] || IMAGE=$(sed -n 's|.*\${P8_CORE_IMAGE:-\(percolationlabs/percolate-core:[0-9][0-9.]*\)}.*|\1|p' \
        dev/docker-compose.yml | head -1)
[ -n "$IMAGE" ] || { echo "no percolate-core image pin in dev/docker-compose.yml" >&2; exit 1; }

psql_() { docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -q "$@"; }

# ------------------------------------------------------------------ the caller
# AN ORDINARY MEMBER, provisioned here, and each half of that is a decision.
#
# ORDINARY, because `member` is what dev/init/02-seed.sql calls "an ordinary
# account" and it is the role that carries `agents:invoke` -- the permission a
# turn actually needs. The first version of this drove the turn as an admin
# instead, which worked and proved less: an admin passing says nothing about
# whether the people who use this can run an agent at all.
#
# PROVISIONED, not borrowed. The second version drove it as alice, the seeded
# user agentic/01-binding.sql reads as, and every turn came back `200` with one
# RUN_ERROR event -- `not authorized to invoke agent percolate ... needs
# agents:invoke`. She does not hold it. A gate whose green depends on which
# permissions the seed happens to have given a particular fixture user is a
# gate that breaks on a seed change having nothing to do with the runtime.
#
# STILL ORDINARY WHERE IT COUNTS: this grants an application role, not a
# Postgres one. The read-back in the .sql runs as `authenticated` with this
# user's claims against the view a caller has, so RLS decides what they see
# exactly as it does for anybody else.
#
# IDEMPOTENT, because this runs on every invocation of the suite. The version
# before this used `rbac.bootstrap_admin`, which is a once-per-database call by
# design -- "only runs while no role has been granted to anyone" -- so it
# passed once and failed every run after it.
#
# AND IT REFUSES RATHER THAN REPAIRS if `member` cannot invoke. Creating the
# grant here would make this gate green on a database where nobody else can run
# an agent, which is the outage dev/tests/content/01 names: "a check that
# refuses everyone is not a check, it is an outage."
if [ "$(psql_ -tAc "select count(*) from rbac.role_permissions
                     where role = 'member' and resource = 'agents' and action = 'invoke'")" != "1" ]; then
    echo "the 'member' role cannot invoke agents on $DB." >&2
    echo "  A turn needs agents:invoke and dev/init/02-seed.sql grants it to member," >&2
    echo "  the ordinary account role. Without it no ordinary user of this database" >&2
    echo "  can run an agent at all, which is a seed regression rather than a" >&2
    echo "  missing fixture -- so this driver refuses instead of granting it." >&2
    exit 1
fi

# ------------------------------------------------------------------ the agent
# PROVISIONED, NOT BORROWED, for the same reason the caller below is.
#
# This drove the seeded `percolate` agent until 2026-09-12, when the core pin
# moved to 0.1.9 and every turn began failing with `LookupError: tool server
# 'p8-query' has no discovered tools`. The seed registers `p8-query` pointing at
# `http://query-mcp:8090` and stores NO catalogue -- discovery is a live HTTP
# call -- and `dev/ci-database.sh` builds a bare container with no query-mcp in
# it. So the seeded agent is unusable in a CI database BY CONSTRUCTION, and was
# only passing because core 0.1.8 raised on set_config long before it got as far
# as resolving a tool.
#
# NOT A PRODUCT DEFECT, checked: `query-mcp` does not appear in
# get-percolate/compose/docker-compose.yml at all, and `p8-query` is not in its
# bootstrap. It is a dev fixture, so a shipped install has no such server and no
# such failure.
#
# WHAT THIS GATE CLAIMS is that a turn reaches the provider through THIS schema
# -- a verified token, a session opened as an ordinary caller, an agent row
# resolved, a run and a message written. A tool catalogue is not on that path,
# so an agent with no tools tests the claim exactly and nothing else.
#
# `"tools": []` EXPLICITLY, NOT BY OMISSION, and this cost a confusing red before
# it was written down. `upsert_agent` carries the column DEFAULT for a key the
# caller omits -- not "no change" -- so an omitted `tools` PRESERVES whatever the
# row already had. That is the same `excluded` behaviour `01-binding.sql` asserts
# about `upsert_tool_server` erasing cached_tools, one table over, and it means a
# probe agent that ever acquired a tool binding keeps it forever: the agent row
# cannot be deleted either, because `runs_agent_id_fkey` holds it once a single
# turn has run. Stating the empty list makes this gate idempotent against a
# database somebody else has poked at, which is the property it claims.
#
# WHAT IT THEREFORE DOES NOT COVER, said here rather than discovered: whether a
# seeded agent's tool bindings still resolve. `dev/tests/agentic/01-binding.sql`
# asserts those as rows, and asserting them through a live turn would need
# query-mcp started beside the runtime -- a second service for a second claim,
# which belongs in its own row if anybody wants it.
psql_ -tAc "
do \$probe\$
begin
    perform agentic.upsert_agent(\$a\$ {
        \"name\": \"$AGENT_NAME\",
        \"audience\": \"user\",
        \"category\": \"general\",
        \"model\": \"$AGENT_MODEL\",
        \"system_prompt\": \"You exist so a gate can prove a turn opens a session. Answer in one word.\",
        \"tools\": []
    } \$a\$::jsonb);
end
\$probe\$;" >/dev/null

SUB=$(psql_ -tAc "
do \$gate\$
declare v_id uuid;
begin
    select id into v_id from rbac.users where email = '$CALLER_EMAIL';
    if v_id is null then
        v_id := rbac.create_user_with_password('$CALLER_EMAIL',
                                               'a long passphrase for the gate');
    end if;
    if not exists (select 1 from rbac.user_roles
                    where user_id = v_id and role = 'member') then
        insert into rbac.user_roles (user_id, role) values (v_id, 'member');
    end if;
end
\$gate\$;
select id from rbac.users where email = '$CALLER_EMAIL';" | tail -1 | tr -d '[:space:]')
[ -n "$SUB" ] || { echo "could not provision the calling user $CALLER_EMAIL" >&2; exit 1; }

# ---------------------------------------------------------------- the runtime
# Reused if it is already up AND pointed at this database. `agent serve` holds
# a pool opened from P8_DSN at start, so one left over from a run against
# another database would answer happily and grade the wrong tree -- the
# `p8-experiment-pg19` failure this collection has already had twice, in a
# container this time.
want_dsn="postgres://authenticator:authpass@127.0.0.1:5432/$DB"
have_dsn=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$AGENT" 2>/dev/null \
           | sed -n 's/^P8_DSN=//p' | head -1 || true)
if [ "$have_dsn" != "$want_dsn" ] || \
   [ "$(docker inspect -f '{{.State.Running}}' "$AGENT" 2>/dev/null || echo false)" != "true" ]; then
    docker rm -f "$AGENT" >/dev/null 2>&1 || true
    docker run -d --name "$AGENT" --network "container:$CONTAINER" \
        -e P8_DSN="$want_dsn" -e P8_JWT_SECRET="$SECRET" \
        "$IMAGE" agent serve >/dev/null
fi

# Ready means ANSWERING, not running. `agent serve` used to bind the
# container's own loopback and report healthy while serving nothing
# (get-percolate's compose records it); asking /_build is asking the thing the
# turn will ask.
BUILD=""
for _ in $(seq 1 30); do
    BUILD=$(docker exec "$AGENT" python -c "
import urllib.request, json, sys
try:
    print(json.load(urllib.request.urlopen('http://127.0.0.1:8080/_build', timeout=2))['build'])
except Exception:
    sys.exit(1)" 2>/dev/null) && [ -n "$BUILD" ] && break
    sleep 1
done
[ -n "$BUILD" ] || {
    echo "the agent runtime never answered /_build. Its log:" >&2
    docker logs "$AGENT" 2>&1 | tail -15 >&2
    exit 1; }

# ---------------------------------------------------------------- the turn
# STDLIB ONLY, inside the image that is already there: no curl in the base, no
# pip install in a gate, and no jwt library on the host. HS256 over two base64
# segments is eight lines and the runtime verifies it with the same secret
# PostgREST uses.
# `-i`, and it is load-bearing: `docker exec` without it gives the command no
# stdin, so `python -` reads nothing, exits 0, and prints nothing. The insert
# below then failed on an empty jsonb rather than on anything about the turn.
OUT=$(docker exec -i -e SECRET="$SECRET" -e SUB="$SUB" -e AGENT_NAME="$AGENT_NAME" "$AGENT" python - <<'PY'
import base64, hashlib, hmac, json, os, time, urllib.error, urllib.request

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
now = int(time.time())
hdr = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
pay = b64(json.dumps({"sub": os.environ["SUB"], "role": "authenticated",
                      "iat": now, "nbf": now - 5, "exp": now + 900},
                     separators=(",", ":")).encode())
msg = hdr + b"." + pay
tok = (msg + b"." + b64(hmac.new(os.environ["SECRET"].encode(), msg,
                                hashlib.sha256).digest())).decode()

body = json.dumps({"model": os.environ["AGENT_NAME"],
                   "messages": [{"role": "user", "content": "say hello"}],
                   "stream": True}).encode()
req = urllib.request.Request("http://127.0.0.1:8080/chat", data=body, headers={
    "Content-Type": "application/json", "Authorization": "Bearer " + tok})

# WHAT IS RECORDED IS HOW FAR IT GOT, not whether it succeeded, and that is the
# point of the whole file. A turn needs a provider key this gate does not have,
# so "it answered" is not the assertion available here. "It reached the model
# call" is, and everything before that point -- verifying the token, opening a
# session as this caller, resolving the agent row, writing the run -- is the
# schema and the build order under test.
result = {"sub": os.environ["SUB"], "status": None, "detail": None,
          "events": [], "session": None}
try:
    resp = urllib.request.urlopen(req, timeout=90)
    result["status"] = resp.status
    result["session"] = resp.headers.get("X-P8-Session-Id")
    raw = resp.read(60000).decode("utf-8", "replace")
    for line in raw.splitlines():
        if line.startswith("data:"):
            try:
                result["events"].append(json.loads(line[5:].strip()))
            except ValueError:
                pass
except urllib.error.HTTPError as e:
    result["status"] = e.code
    result["detail"] = e.read(4000).decode("utf-8", "replace")
except Exception as e:                                    # noqa: BLE001
    result["status"] = -1
    result["detail"] = f"{type(e).__name__}: {e}"
print(json.dumps(result))
PY
)

# The agent's stderr carries the refusal a 500 does not, and the assertions ask
# about it by name. Captured at the same moment as the response so the two
# describe one turn.
LOG=$(docker logs --tail 40 "$AGENT" 2>&1 | tail -40)

# ---------------------------------------------------------------- record it
# UNLOGGED and dropped-then-created: this is staging for one assertion, not
# state, and a leftover row from the previous run is the shape that makes a
# suite report the last person's setup (dev/check.sh's --fixture comment).
#
# Written as the SUPERUSER on purpose. The turn was driven as an ordinary
# caller and that is what is under test; the transcript OF it is evidence, and
# evidence a caller could rewrite is not evidence.
# THROUGH STDIN, NOT `-c`, and that is not style. psql does not interpolate
# `:'var'` in a `-c` string -- it goes to the server as typed and Postgres
# reports `syntax error at or near ":"`, which reads like a broken statement
# rather than a missing substitution. Over stdin the psql parser sees it and
# `:'var'` quotes the value properly, which matters because the agent log is
# arbitrary multi-line text with quotes in it.
psql_ -v image="$IMAGE" -v build="$BUILD" -v log="$LOG" -v res="$OUT" >/dev/null <<'SQL'
drop table if exists public.p8_test_agent_turn;
create unlogged table public.p8_test_agent_turn (
    driven_at timestamptz not null default now(),
    image     text,
    build     text,
    agent_log text,
    result    jsonb
);
revoke all on public.p8_test_agent_turn from public;
insert into public.p8_test_agent_turn (image, build, agent_log, result)
values (:'image', :'build', :'log', :'res'::jsonb);
SQL

echo "drove a turn against $IMAGE (build $BUILD)"
