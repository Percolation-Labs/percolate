-- THE LANGGRAPH ARTICLE RUNS, BLOCK FOR BLOCK (REM-957).
--
-- "Percolate for LangGraph Users" (Percolate writing ld-83cdc18c9991) was drafted from the 0.2.22 docs and never
-- run. Run on 0.2.23 it failed in four places: the saga and the worked example did not compile (`compensate_with`
-- named steps that did not exist), the waiting fragment needed a step it did not show, and `session_group` never
-- shared a conversation with the real runtime. An article is a test, so this
-- file is the canonical copy of every workflow and SQL block in it. The article quotes these blocks; when one
-- changes here, it changes there.
--
--   §1  the tool server an agent row names
--   §2  a chain: each step waits on the one before and reads its result
--   §3  three steps start together and the fourth waits for all of them
--   §4  routing is an agent whose tools are other agents
--   §5  a matrix fans out over a query, and over an earlier step's output
--   §7  two steps in one session_group carry one session id, and its row exists for the runtime to continue
--   §8  a timer holds the run with nothing claimable, then a signal releases it
--   §9  a saga that fails undoes its writes in reverse order
--   §10 the run is the trace
--   §11 the insurance claim, end to end: parallel checks, a join, an adjuster, a failed transfer, a reversal
--
-- Agent steps are http_call tasks on the `http` queue. Nothing here has an Agent Runtime, so pg_temp.work plays
-- the worker: it claims each task, reads its context through get_task_context as the worker does, and answers
-- by step name. The live run behind this file used the published compose stack with dev/faultsrv as the model.
--
-- What does not run here runs live: the article's shell and compose blocks, between `-- live: <name>` and
-- `-- /live` where the article has them, each line behind "-- ". A shell block carries no `#` comment: macOS's
-- interactive zsh does not treat `#` as one, so an apostrophe in a comment opened a quote and the first block
-- never ran (REM-957's fifth reader); the live run parses each in `zsh -f -i -n` first. It takes each out, drops that prefix,
-- and runs it as the reader would, in one shell whose variables and functions carry from block to block, with the
-- SQL in one psql session. It changes only what this machine forces: the project and directory name, the ports in
-- the stack's .env (and the content and MinIO ports, taken here too), the image (P8_DB_IMAGE in .env, when a
-- run tests a local build), and the model. dev/faultsrv
-- joins the stack through COMPOSE_FILE, OPENAI_BASE_URL points the agents at it, and the agent rows script it,
-- so every request is the reader's word for word.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

-- The article's reader. A stack the article was followed on already has them.
insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000025a1', 'me@example.com', 'active')
on conflict (email) do nothing;
-- bootstrap_admin makes the reader an administrator; section 4 creates a second person and an org as them.
insert into rbac.user_roles (user_id, role)
select id, 'admin' from rbac.users where email = 'me@example.com'
on conflict do nothing;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'langgraph article: %', p_what;
    end if;
end $$ language plpgsql;

-- Start a workflow as the reader, the way a REST call with their token does.
create function pg_temp.start(p_name text, p_input jsonb default '{}') returns uuid as $$
declare v_run uuid;
begin
    perform set_config('request.jwt.claims', json_build_object('sub',
        (select id from rbac.users where email = 'me@example.com'), 'role', 'authenticated')::text, true);
    v_run := workflow.start_workflow(p_name, p_input);
    perform set_config('request.jwt.claims', '', true);
    return v_run;
end $$ language plpgsql;

-- The worker, for the http tasks the run has ready NOW: one wave, so a step its own completion frees waits for the
-- next call. Returns how many it ran.
create function pg_temp.work(p_run uuid) returns int as $$
declare t workflow.tasks; v_ctx jsonb; v_n int := 0;
    v_wave int := (select count(*) from workflow.tasks
                    where run_id = p_run and queue = 'http' and status = 'ready');
begin
    for i in 1 .. v_wave loop
        select * into t from workflow.claim_task('http', 'wf25');
        perform pg_temp.check(t.run_id = p_run, 'the worker claimed a task of another run: ' || t.step_key);
        v_ctx := workflow.get_task_context(t.id, 'wf25');
        v_n := v_n + 1;
        if t.step_key = 'transfer' then
            perform workflow.fail_task(t.id, '{"error": "http_call returned HTTP 404"}', true, 'wf25');
        else
            perform workflow.complete_task(t.id, jsonb_build_object('status', 200, 'result',
                case when t.step_key = 'fraud' then
                          jsonb_build_object('score', case when (select input->>'claim_id' from workflow.runs
                                                                  where id = t.run_id) = '7' then 0.82 else 0.12 end)
                     when t.step_key = 'plan'  then '{"sections": ["intro", "method", "results"]}'::jsonb
                     when t.step_key = 'generate' then
                          to_jsonb(case when (select input->>'topic' from workflow.runs where id = t.run_id) = 'puns'
                                        then 'Why did the tide turn? It had a change of heart!'
                                        else 'a joke about harbours' end)
                     when t.step_key = 'grade_1' then '{"grade": "not funny", "feedback": "shorter"}'::jsonb
                     when t.step_key like 'grade\_%' then '{"grade": "funny", "feedback": "keep it"}'::jsonb
                     else to_jsonb('answer from ' || t.step_key) end), 'wf25');
        end if;
    end loop;
    return v_n;
end $$ language plpgsql;

-- Whether the installed parser is the one this tree compiles (dev/tests/run.sh, "requires-parser"). Its absence asserts:
-- a database whose parser lags its SQL (the published image under a newer tree) defers only what the parser decides.
create function pg_temp.parser_current() returns boolean language sql stable as $$
    select coalesce((select p.extversion = c.extversion
                       from pg_catalog.pg_extension p, pg_catalog.pg_extension c
                      where p.extname = 'percolate_parser' and c.extname = 'percolate'), false)
       and coalesce(current_setting('percolate.parser_behind', true), 'absent') <> 'yes';
$$;

create function pg_temp.status(p_run uuid, p_step text) returns text as $$
    select status from workflow.tasks where run_id = p_run and step_key = p_step
$$ language sql;


-- Before you start -----------------------------------------------------------------------------------------------
-- live: stack
-- mkdir langgraph-tour && cd langgraph-tour
-- curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml \
--   -o docker-compose.yml
-- cat > .env <<'EOF'
-- COMPOSE_PROJECT_NAME=langgraph-tour
-- P8_PG_PORT=5432
-- P8_REST_PORT=3000
-- P8_AGENT_PORT=8080
-- P8_CONTENT_PORT=8081
-- P8_MINIO_PORT=9000
-- P8_MINIO_CONSOLE_PORT=9001
-- P8_QUERY_MCP_PORT=8090
-- OPENAI_API_KEY=sk-your-key
-- EOF
-- docker compose up -d --wait
-- /live
-- live: venv
-- python3 -c 'import sys; sys.exit(sys.version_info < (3, 11) and "Percolate needs Python 3.11 or newer: use python3.11 or python3.13 in place of python3")' &&
--   python3 -m venv .venv && . .venv/bin/activate &&
--   pip install 'percolate-core[sample,agent]==0.2.16'
-- /live
-- live: shell
-- set -a; . ./.env; set +a
-- export PAGER=cat
-- export P8_DSN=postgres://p8:p8@localhost:$P8_PG_PORT/percolate
-- export P8_ADMIN_DSN=$P8_DSN
-- export P8_JWT_SECRET=change-me-a-long-random-string-at-least-32-chars
-- REST=http://localhost:$P8_REST_PORT
-- AGENT=http://localhost:$P8_AGENT_PORT
--
-- psql "$P8_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')"
-- export P8_USER_ID=$(psql "$P8_DSN" -Atc "select id from rbac.users where email = 'me@example.com'")
-- export TOKEN=$(percolate auth token --email me@example.com)
--
-- start() {
--   r=$(curl -s $REST/rpc/start_workflow \
--     -H 'Content-Profile: workflow' -H "Authorization: Bearer $TOKEN" \
--     -H 'Content-Type: application/json' \
--     -d "{\"p_name\": \"$1\", \"p_input\": $2}" | jq -r .)
--   case $r in
--     ????????-????-????-????-????????????) echo "$r" ;;
--     *) echo "start $1 failed: $r" >&2; return 1 ;;
--   esac
-- }
--
-- show() {
--   for i in $(seq 150); do
--     [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$1'")" != running ] && break
--     sleep 2
--   done
--   psql "$P8_DSN" -c "select status, compensation_state from workflow.runs where id = '$1'" \
--     -c "select step_key, status, left(output->>'result', 60) as result,
--                left(coalesce(error->>'error', error::text), 120) as error
--         from workflow.tasks where run_id = '$1'
--         order by completed_at nulls last, step_key"
-- }
--
-- waiting() {
--   for i in $(seq 90); do
--     s=$(psql "$P8_DSN" -Atc "select status from workflow.tasks where run_id = '$1' and step_key = '$2'")
--     case $s in waiting_external|succeeded|skipped|failed|cancelled) break ;; esac
--     sleep 2
--   done
--   echo "$s"
-- }
-- /live

-- The fleet the harbourmaster queries: dev/tests/query/16's article block, verbatim (REM-984).
-- block: fleet
-- Percolate: the fleet the harbourmaster queries. Synthetic, CC0-1.0.
do $$ begin
  if not exists (select 1 from rbac.users where email = 'me@example.com') then
    raise exception 'run the bootstrap_admin step first: the fleet belongs to me@example.com';
  end if;
end $$;

create schema if not exists fleet;
comment on schema fleet is
  'A synthetic fleet for the LangGraph tour, released under CC0-1.0. Ships, operators and berths are '
  'invented; the ports are real. Every IMO number fails the IMO check digit, so none is a real ship.';

create table if not exists fleet.vessels (
  id int primary key, name text not null unique, imo text not null unique,
  operator text not null, type text not null, gross_tonnage int not null,
  owner_id uuid not null);
create table if not exists fleet.berths (
  id int primary key, port text not null, code text not null,
  max_draught_m numeric(4,1) not null, length_m int not null,
  owner_id uuid not null, unique (port, code));
create table if not exists fleet.port_calls (
  id int primary key, vessel_id int not null references fleet.vessels,
  berth_id int not null references fleet.berths,
  arrived_at timestamptz not null, departed_at timestamptz,  -- null: alongside now
  purpose text not null, owner_id uuid not null);
comment on column fleet.port_calls.departed_at is 'null while the vessel is still alongside';
comment on table fleet.vessels    is 'Synthetic tour data (CC0-1.0): the fleet. IMO numbers fail the check digit on purpose.';
comment on table fleet.berths     is 'Synthetic tour data (CC0-1.0): berths at real ports, with invented codes and sizes.';
comment on table fleet.port_calls is 'Synthetic tour data (CC0-1.0): one row per call; departed_at is null while alongside.';

with me as (select id from rbac.users where email = 'me@example.com')
insert into fleet.vessels select v.*, me.id from me, (values
  (1, 'Meridian Dawn',  '9331802', 'Meridian Line',    'container ship',  38200),
  (2, 'Meridian Star',  '9331803', 'Meridian Line',    'container ship',  38200),
  (3, 'Bulk Harmony',   '9407711', 'Meridian Bulk',    'bulk carrier',    31900),
  (4, 'Aurora Kestrel', '9214578', 'Kestrel Shipping', 'general cargo',    8450),
  (5, 'Kestrel Tern',   '9512340', 'Kestrel Shipping', 'general cargo',    8450),
  (6, 'Nordvik Spirit', '9620012', 'Nordvik Chartering', 'product tanker', 23400))
  v(id, name, imo, operator, type, gross_tonnage)
on conflict (id) do nothing;

with me as (select id from rbac.users where email = 'me@example.com')
insert into fleet.berths select b.*, me.id from me, (values
  (1, 'Rotterdam',  'Amazonehaven 4', 15.0, 380),
  (2, 'Rotterdam',  'Waalhaven 2',    11.5, 240),
  (3, 'Felixstowe', 'Trinity 6',      14.5, 350),
  (4, 'Felixstowe', 'Landguard 1',     9.0, 180),
  (5, 'Gothenburg', 'Skandia 3',      13.0, 300),
  (6, 'Gothenburg', 'Energy Port 9',  12.0, 230))
  b(id, port, code, max_draught_m, length_m)
on conflict (id) do nothing;

with me as (select id from rbac.users where email = 'me@example.com')
insert into fleet.port_calls select c.*, me.id from me, (values
  ( 1, 1, 1, timestamptz '2026-10-02 06:10Z', timestamptz '2026-10-03 21:40Z', 'discharge'),
  ( 2, 1, 3, timestamptz '2026-10-09 14:00Z', timestamptz '2026-10-10 18:25Z', 'load'),
  ( 3, 2, 3, timestamptz '2026-10-04 08:30Z', timestamptz '2026-10-05 19:00Z', 'discharge'),
  ( 4, 2, 1, timestamptz '2026-10-17 05:45Z', null,                           'load'),
  ( 5, 3, 2, timestamptz '2026-10-06 11:20Z', timestamptz '2026-10-09 07:15Z', 'discharge'),
  ( 6, 3, 5, timestamptz '2026-10-15 16:00Z', null,                           'repairs'),
  ( 7, 4, 4, timestamptz '2026-10-01 09:00Z', timestamptz '2026-10-01 22:30Z', 'load'),
  ( 8, 4, 6, timestamptz '2026-10-12 07:40Z', timestamptz '2026-10-13 12:10Z', 'bunkers'),
  ( 9, 5, 2, timestamptz '2026-10-18 13:15Z', null,                           'discharge'),
  (10, 6, 6, timestamptz '2026-10-08 03:50Z', timestamptz '2026-10-08 20:05Z', 'discharge'),
  (11, 6, 2, timestamptz '2026-10-14 10:30Z', timestamptz '2026-10-16 02:00Z', 'load'))
  c(id, vessel_id, berth_id, arrived_at, departed_at, purpose)
on conflict (id) do nothing;

-- Readable by its owner and nobody else, through the same policy shape the extension's own tables use.
grant usage on schema fleet to authenticated;
grant select on fleet.vessels, fleet.berths, fleet.port_calls to authenticated;
alter table fleet.vessels    enable row level security;
alter table fleet.berths     enable row level security;
alter table fleet.port_calls enable row level security;
drop policy if exists owner_reads on fleet.vessels;
drop policy if exists owner_reads on fleet.berths;
drop policy if exists owner_reads on fleet.port_calls;
create policy owner_reads on fleet.vessels    for select using (owner_id = (select rbac.current_user_id()));
create policy owner_reads on fleet.berths     for select using (owner_id = (select rbac.current_user_id()));
create policy owner_reads on fleet.port_calls for select using (owner_id = (select rbac.current_user_id()));

select (select count(*) from fleet.vessels) as vessels, (select count(*) from fleet.berths) as berths,
       (select count(*) from fleet.port_calls) as port_calls;
-- /block
-- live: fleet_schema
-- curl -s $REST/rpc/query \
--   -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
--   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"p_query": "SCHEMA \"sql\" FROM port_calls"}'; echo
-- /live
-- live: fleet_curl
-- curl -s $REST/rpc/sql_passthrough \
--   -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
--   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"p_statement": "select v.name, v.imo, b.port, b.code as berth, c.arrived_at, c.purpose from fleet.port_calls c join fleet.vessels v on v.id = c.vessel_id join fleet.berths b on b.id = c.berth_id where c.departed_at is null order by c.arrived_at"}'; echo
-- /live

select pg_temp.check((select count(*) from fleet.port_calls where departed_at is null) = 3,
    'before you start: three vessels are alongside');


-- §1 ------------------------------------------------------------------------------------------------------------
-- block: harbourmaster
select (agentic.upsert_agent($j${
  "name": "harbourmaster",
  "model": "openai:gpt-4o-mini",
  "system_prompt": "You answer questions about the fleet, which is in fleet.vessels, fleet.berths and fleet.port_calls. A vessel is alongside while its port call has no departed_at. Query those tables in SQL; start with SCHEMA \"sql\" FROM port_calls if you need the columns. Never guess a vessel name.",
  "tools": [{"server": "harbour-query", "tools": ["query"]}]
}$j$::jsonb)).name;

select (agentic.upsert_tool_server($j${
  "name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090"
}$j$::jsonb)).name;
-- /block

select pg_temp.check(exists (select 1 from agentic.tool_servers where name = 'harbour-query')
    and exists (select 1 from agentic.agents where name = 'harbourmaster'), '§1 the agent and its tool server are rows');
-- live: chat
-- curl -s -X POST $AGENT/tools/harbour-query/sync -H "Authorization: Bearer $TOKEN"; echo
--
-- curl -sN $AGENT/chat -D headers.txt \
--   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"model": "harbourmaster", "stream": true,
--        "messages": [{"role": "user", "content": "Which vessels are alongside right now?"}]}'
-- /live
-- block: retell
update agentic.agents set system_prompt = system_prompt || ' Answer in French.'
 where name = 'harbourmaster';
-- /block
-- live: chat_again
-- curl -sN $AGENT/chat \
--   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"model": "harbourmaster", "stream": true,
--        "messages": [{"role": "user", "content": "Which vessels are alongside right now?"}]}'
-- /live
-- block: versions
select version, left(system_prompt, 60) as prompt, held_from, replaced_at, replaced_by_role
  from agentic.agent_versions_api where name = 'harbourmaster' order by version;
-- /block

select pg_temp.check((select count(*) from agentic.agent_versions_api where name = 'harbourmaster') = 1
    and (select system_prompt from agentic.agent_versions_api where name = 'harbourmaster') not like '%French%',
    '§1 the change wrote one version, holding the prompt it replaced');


-- §2 ------------------------------------------------------------------------------------------------------------
-- The agents every workflow below names. The draft used them and never made them; define_yaml only warns.
-- block: agents
select (agentic.upsert_agent(jsonb_build_object(
         'name', name, 'model', 'openai:gpt-4o-mini', 'system_prompt', prompt))).name
from (values
  ('joker',      'Write one short joke on the topic you are given.'),
  ('writer',     'Write what you are asked for, in under 150 words.'),
  ('editor',     'Combine the pieces you are given into one short piece.'),
  ('planner',    'List the sections a short report on the topic needs.'),
  ('psc_report_extractor',
                 'Read a port state control inspection note and list each deficiency it records, '
                 'quoting the note, or say it records none. Add nothing the note does not say.'),
  ('classifier', 'Classify a safety report as SAFETY, FINANCE or OTHER, with one sentence why.'),
  ('researcher', 'Say what an inspector should check next, given the classification before you.'),
  ('fraud_scorer', 'Score an insurance claim for fraud risk.'),
  ('document_reviewer',
                 'Given the documents a hull damage claim lists, say which ones such a claim '
                 'usually also needs and whether any are missing. You cannot open the files.'),
  ('assessor',   'From the fraud score, cover check and document review of a claim, recommend '
                 'pay, investigate or refuse, with one reason.'),
  ('critic',     'Grade a joke funny or not funny, with one line of feedback.')) a(name, prompt);
-- /block

select pg_temp.check((select count(*) from agentic.agents where name in ('joker', 'writer', 'assessor')) = 3,
    '§2 the agents are rows');

-- block: joke
select workflow.define_yaml($y$
name: joke
steps:
  - id: generate
    agent: joker
    input: 'Write a short joke about {{run.topic}}'
  - id: improve
    needs: [generate]
    when: "'{{steps.generate.result}}' !~ '[?!]'"
    agent: joker
    input: 'Make this funnier with wordplay: {{steps.generate.result}}'
  - id: polish
    needs: [improve]
    when: "{{steps.improve.result}} is not null"
    agent: joker
    input: 'Add a surprising twist: {{steps.improve.result}}'
$y$);
-- /block
-- live: start_joke
-- RUN=$(start joke '{"topic": "harbours"}')
-- show $RUN
-- /live

do $$
declare r uuid := pg_temp.start('joke', '{"topic": "harbours"}');
begin
    perform pg_temp.check(pg_temp.status(r, 'generate') = 'ready' and pg_temp.status(r, 'improve') = 'pending',
        '§2 only the first step of a chain is claimable');
    perform pg_temp.check(pg_temp.work(r) = 1 and pg_temp.work(r) = 1 and pg_temp.work(r) = 1,
        '§2 each step frees the next');
    perform pg_temp.check((select status from workflow.runs where id = r) is not distinct from 'succeeded', '§2 the chain finishes');
end $$;

-- The gate: a joke that already has its punchline skips the rest (REM-967).
do $$
declare r uuid := pg_temp.start('joke', '{"topic": "puns"}');
begin
    perform pg_temp.check(pg_temp.work(r) = 1, '§2 the joke is written');
    perform pg_temp.check(pg_temp.status(r, 'improve') = 'skipped' and pg_temp.status(r, 'polish') = 'skipped',
        '§2 a joke with a punchline skips improve and polish');
    perform pg_temp.check((select status from workflow.runs where id = r) is not distinct from 'succeeded', '§2 and the run succeeds');
end $$;

-- §2's prose: a chain of query steps has finished by the time start_workflow returns.
select workflow.define_yaml($y$
name: query_chain
steps:
  - {id: a, sql: "select 1 as n"}
  - {id: b, needs: [a], sql: "select {{steps.a.result.0.n}} + 1 as n"}
$y$);

do $$
declare r uuid := pg_temp.start('query_chain');
begin
    perform pg_temp.check((select status from workflow.runs where id = r) is not distinct from 'succeeded'
        and (select output #>> '{result,0,n}' from workflow.tasks where run_id = r and step_key = 'b') is not distinct from '2',
        '§2 query steps finish inside start_workflow');
end $$;


-- §3 ------------------------------------------------------------------------------------------------------------
-- block: compare
select workflow.define_yaml($y$
name: compare
steps:
  - {id: joke,  agent: writer, input: 'A joke about {{run.topic}}'}
  - {id: story, agent: writer, input: 'A story about {{run.topic}}'}
  - {id: poem,  agent: writer, input: 'A poem about {{run.topic}}'}
  - id: combine
    needs: [joke, story, poem]
    agent: editor
    input: '{{steps.story.result}} {{steps.joke.result}} {{steps.poem.result}}'
$y$);
-- /block
-- live: start_compare
-- RUN=$(start compare '{"topic": "tides"}')
-- show $RUN
-- /live
-- live: compare_times
-- psql "$P8_DSN" -c "select step_key, to_char(claimed_at, 'HH24:MI:SS.MS') as claimed,
--   to_char(completed_at, 'HH24:MI:SS.MS') as finished
--   from workflow.tasks where run_id = '$RUN' order by claimed_at, step_key"
-- /live

do $$
declare r uuid := pg_temp.start('compare', '{"topic": "tides"}');
begin
    perform pg_temp.check(pg_temp.work(r) = 3, '§3 three steps with no dependency start together');
    perform pg_temp.check(pg_temp.work(r) = 1, '§3 the join runs once all three are back');
    perform pg_temp.check((select status from workflow.runs where id = r) is not distinct from 'succeeded', '§3 the run finishes');
end $$;


-- §4 ------------------------------------------------------------------------------------------------------------
-- block: p8-agents
select (agentic.upsert_tool_server($j${
  "name": "p8-agents", "kind": "mcp",
  "url": "http://agent:8080/mcp", "serves_agents": true
}$j$::jsonb)).name;
-- /block

-- Bob's block, run for real (REM-985; the mechanism is dev/tests/rbac/22).
-- block: reach
-- You, signed in as yourself
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false) is not null as signed_in;

-- A second person, and a harbour office you both belong to
select rbac.create_user_with_password('crew@example.com', 'a-long-crew-password-123') is not null as crew_created;
select rbac.grant_role((select id from rbac.users where email = 'crew@example.com'), 'member');
select rbac.create_org('harbour-office', 'Harbour office') is not null as office_created;
select rbac.add_org_member((select id from rbac.orgs where slug = 'harbour-office'),
                           (select id from rbac.users where email = 'crew@example.com'));

-- Your three writers stay yours. The router is shared with the office.
select (agentic.upsert_agent(jsonb_build_object('name', w,
          'system_prompt', 'Write a short ' || w || ' about what you are given.',
          'visibility', 'private'))).name
  from unnest(array['story', 'joke', 'poem']) w;

select (agentic.upsert_agent(jsonb_build_object('name', 'router',
          'system_prompt', 'Hand the request to the story, joke or poem writer.',
          'org_id', (select id from rbac.orgs where slug = 'harbour-office'), 'visibility', 'org',
          'tools', '[{"server": "p8-agents",
                      "tools": ["agent__story", "agent__joke", "agent__poem"]}]'::jsonb))).name;

-- What the router can hand on, for you: the agents you may invoke
select name, visibility, agentic.may_invoke(name) as you_may_invoke
  from agentic.agents_api where name in ('router', 'story', 'joke', 'poem') order by name;

-- The same question, asked as crew
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'crew@example.com'))::text, false) is not null as signed_in_as_crew;
select name, visibility, agentic.may_invoke(name) as crew_may_invoke
  from agentic.agents_api where name in ('router', 'story', 'joke', 'poem') order by name;
-- /block

select pg_temp.check(not agentic.may_invoke('story') and agentic.may_invoke('router'),
    '§4 crew may invoke the router and not the writers');

\set ON_ERROR_STOP off
savepoint refused_route;
-- block: refused_route
-- And if the router hands crew's request to a writer anyway, the run is refused by name
select agentic.start_run('story');
-- /block
rollback to savepoint refused_route;
\set ON_ERROR_STOP on
select pg_temp.check(:'LAST_ERROR_MESSAGE' = 'not authorized to invoke agent story',
    '§4 crew''s run of a writer is refused by name: ' || :'LAST_ERROR_MESSAGE');

-- block: back_to_me
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false) is not null as signed_in;
-- /block
select pg_temp.check(agentic.may_invoke('story'), '§4 signed back in, you may invoke every writer');
select set_config('request.jwt.claims', '', false);
-- live: sync
-- curl -s -X POST $AGENT/tools/p8-agents/sync \
--   -H "Authorization: Bearer $TOKEN"; echo
-- /live


select pg_temp.check((select tools from agentic.agents where name = 'router')
    is not distinct from '[{"server": "p8-agents", "tools": ["agent__story", "agent__joke", "agent__poem"]}]', '§4 the allowlist is a row');


-- §5 ------------------------------------------------------------------------------------------------------------
-- block: reports
create table reports (id int primary key, content text, extracted_at timestamptz, extraction text);
grant select, update on reports to authenticated;
insert into reports (id, content) values
  (1, 'Deficiency: fire door'), (2, 'Deficiency: lifeboat davit'), (3, 'No deficiencies');

create function land_extractions(p_matrix_task uuid) returns jsonb language sql as $$
  with done as (
    update reports r set extraction = o->'output'->>'result', extracted_at = now()
    from jsonb_array_elements(workflow.matrix_outputs(p_matrix_task)) o
    where r.id = (o->'item'->>'id')::int and o->>'status' = 'succeeded'
    returning 1)
  select jsonb_build_object('landed', count(*)) from done
$$;
select 'land_extractions registered'
from workflow.register_step_function('land_extractions', 'public.land_extractions', array['uuid']);
-- /block

-- block: extract_reports
select workflow.define_yaml($y$
name: extract_reports
steps:
  - id: extract
    matrix:
      rows: "select id, content from reports where extracted_at is null"
      max_fanout: 500
      continue_on: failed
      min_success: 0.9
      template:
        agent: psc_report_extractor
        input: '{{item.content}}'
  - id: land
    needs: [extract]
    sql: {function: land_extractions, args: ['{{steps.extract.result.task_id}}']}
$y$);
-- /block
-- live: start_extract_reports
-- RUN=$(start extract_reports '{}')
-- show $RUN
-- psql "$P8_DSN" -c "select id, left(extraction, 60) as extraction from reports order by id"
-- /live

do $$
declare r uuid := pg_temp.start('extract_reports', '{}');
begin
    perform pg_temp.check(pg_temp.work(r) = 3, '§5 one child per row');
    perform pg_temp.check((select output #>> '{result,landed}' from workflow.tasks
                            where run_id = r and step_key = 'land') is not distinct from '3', '§5 the fan-in lands every child');
    perform pg_temp.check((select count(*) from reports where extracted_at is not null) = 3,
        '§5 every report is extracted');
end $$;

-- The draft named this a gap. It is not: the rows can come from an earlier step's output.
-- block: write_report
select workflow.define_yaml($y$
name: write_report
steps:
  - id: plan
    agent: planner
    input: 'List the sections of a report on {{run.topic}}'
    output_schema:
      type: object
      required: [sections]
      properties: {sections: {type: array, items: {type: string}}}
  - id: write
    needs: [plan]
    matrix:
      rows: "select value as section from jsonb_array_elements_text(({{steps.plan.result.sections}})::jsonb)"
      max_fanout: 20
      template:
        agent: writer
        input: 'Write the {{item.section}} section of a report on {{run.topic}}'
$y$);
-- /block
-- live: start_write_report
-- RUN=$(start write_report '{"topic": "port state control"}')
-- show $RUN
-- /live

do $$
declare r uuid := pg_temp.start('write_report', '{"topic": "port state control"}');
begin
    perform pg_temp.check(pg_temp.work(r) = 1, '§5 the plan runs first');
    perform pg_temp.check(pg_temp.work(r) = 3, '§5 the width came from the plan');
    perform pg_temp.check((select array_agg(input#>>'{item,section}' order by step_key) from workflow.tasks
                            where run_id = r and step_key like 'write[%')
        is not distinct from array['intro', 'method', 'results'], '§5 each child got its section');
end $$;


-- §6 ------------------------------------------------------------------------------------------------------------
-- block: joke_until_funny
select workflow.define_yaml($y$
name: joke_until_funny
steps:
  - id: refine
    repeat:
      max: 3
      until: "'{{steps.grade.result.grade}}' = 'funny'"
      steps:
        - id: write
          agent: joker
          input: 'Write a joke about {{run.topic}}. {{previous.grade.result.feedback}}'
        - id: grade
          needs: [write]
          agent: critic
          input: 'Grade this joke funny or not funny, with feedback: {{steps.write.result}}'
          output_schema:
            type: object
            required: [grade, feedback]
            properties:
              grade: {type: string, enum: [funny, not funny]}
              feedback: {type: string}
  - id: tell
    needs: [refine]
    sql: "select '{{steps.refine.result.0.last.write}}' as joke, {{steps.refine.result.0.attempts}} as attempts"
$y$);
-- /block
-- live: start_joke_until_funny
-- RUN=$(start joke_until_funny '{"topic": "pilots"}')
-- show $RUN
-- /live

do $$
declare r uuid := pg_temp.start('joke_until_funny', '{"topic": "pilots"}');
begin
    perform pg_temp.check(pg_temp.work(r) = 1 and pg_temp.work(r) = 1, '§6 the first attempt writes, then grades');
    perform pg_temp.check(pg_temp.work(r) = 1 and pg_temp.work(r) = 1, '§6 graded not funny, a second attempt runs');
    perform pg_temp.check(pg_temp.status(r, 'write_3') = 'skipped' and pg_temp.status(r, 'grade_3') = 'skipped',
        '§6 graded funny, the third attempt is skipped');
    perform pg_temp.check((select output->'result'->0 @> '{"attempts": 2, "satisfied": true}' from workflow.tasks
                            where run_id = r and step_key = 'refine'), '§6 the repeat reports two attempts, satisfied');
    perform pg_temp.check((select output#>>'{result,0,attempts}' from workflow.tasks
                            where run_id = r and step_key = 'tell') is not distinct from '2'
        and (select status from workflow.runs where id = r) is not distinct from 'succeeded', '§6 the step after the repeat reads it');
end $$;


-- §7 ------------------------------------------------------------------------------------------------------------
-- block: triage_then_research
select workflow.define_yaml($y$
name: triage_then_research
steps:
  - {id: triage,    agent: classifier, session_group: analysis, input: 'Classify: {{run.report}}'}
  - {id: deep_dive, agent: researcher, session_group: analysis, needs: [triage],
     input: 'Research the class you chose'}
$y$);
-- /block
-- live: start_triage_then_research
-- RUN=$(start triage_then_research '{"report": "fire door held open"}')
-- show $RUN
-- /live

do $$
declare
    r uuid := pg_temp.start('triage_then_research', '{"report": "fire door held open"}');
    v_sid uuid := workflow.run_session(r, 'analysis');
    t workflow.tasks; v_ctx jsonb;
begin
    -- REM-957: the compiled body said `session`, which the runtime ignores, and the id had no row, which it 404s.
    select * into t from workflow.claim_task('http', 'wf25') where run_id = r;
    v_ctx := workflow.get_task_context(t.id, 'wf25');
    -- The key the runtime reads is the compiler's (#460, plan_graph.rs); that the group's session reaches the step
    -- is the engine's, and holds whichever key a lagging parser spelled it under.
    if pg_temp.parser_current() then
        perform pg_temp.check((v_ctx #>> '{task_input,body,session_id}')::uuid = v_sid,
            '§7 the step sends the group''s session as session_id');
    else
        perform pg_temp.check(coalesce(v_ctx #>> '{task_input,body,session_id}',
                                       v_ctx #>> '{task_input,body,session}')::uuid = v_sid,
            '§7 the step carries the group''s session');
        raise notice 'DEFERRED: workflow/25 §7 the session sent as session_id -- the compiled parser (%) predates '
                     'the extension SQL (%), and the key is the compiler''s',
            (select extversion from pg_catalog.pg_extension where extname = 'percolate_parser'),
            (select extversion from pg_catalog.pg_extension where extname = 'percolate');
    end if;
    perform pg_temp.check(exists (select 1 from agentic.sessions where id = v_sid
                                   and owner_id = (select id from rbac.users where email = 'me@example.com')),
        '§7 the session row exists, owned by the person who started the run');
    perform workflow.complete_task(t.id, '{"status": 200, "result": "safety"}', 'wf25');

    select * into t from workflow.claim_task('http', 'wf25') where run_id = r;
    v_ctx := workflow.get_task_context(t.id, 'wf25');
    perform pg_temp.check(t.step_key = 'deep_dive'
        and coalesce(v_ctx #>> '{task_input,body,session_id}', v_ctx #>> '{task_input,body,session}')::uuid = v_sid,
        '§7 both steps carry one session');
    perform workflow.complete_task(t.id, '{"status": 200, "result": "done"}', 'wf25');
    perform set_config('session.id', v_sid::text, false);
end $$;

-- live: session (after chat)
-- SID=$(awk 'tolower($1) == "x-p8-session-id:" {print $2}' headers.txt | tr -d '\r')
-- curl -sN $AGENT/chat -H "X-P8-Session-Id: $SID" \
--   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"model": "harbourmaster", "stream": true,
--        "messages": [{"role": "user", "content": "And the second one?"}]}'
-- /live


-- §8 ------------------------------------------------------------------------------------------------------------
-- block: release_vessel
select workflow.define_yaml($y$
name: release_vessel
steps:
  - id: notice
    sql: "select 'detention notice served' as notice"
  - id: cooling_off
    needs: [notice]
    timer: 5            # seconds; a real cooling-off would be 3600 or more
  - id: approve
    needs: [cooling_off]
    signal: true
$y$);
-- /block
-- live: start_release_vessel
-- RUN=$(start release_vessel '{}')
-- /live

do $$
declare r uuid := pg_temp.start('release_vessel', '{}');
begin
    perform pg_temp.check(pg_temp.status(r, 'cooling_off') = 'ready'
        and (select run_after from workflow.tasks where run_id = r and step_key = 'cooling_off')
            > now(), '§8 the timer holds the step');
    perform pg_temp.check(pg_temp.status(r, 'approve') = 'pending', '§8 the signal waits behind the timer');

    -- An hour passes.
    update workflow.tasks set run_after = now() where run_id = r and step_key = 'cooling_off';
    perform workflow.promote_due_timers();
    perform pg_temp.check(pg_temp.status(r, 'approve') = 'waiting_external', '§8 then the run waits for a person');

    perform set_config('run.id', r::text, true);
end $$;

-- live: waiting
-- waiting $RUN approve
-- /live
-- Crew, from section 4, tries to sign first.
\set ON_ERROR_STOP off
savepoint crew_signs;
-- block: crew_signs
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'crew@example.com'))::text, false);

select workflow.signal_task(
  (select r.id from workflow.runs r
     join workflow.definitions d on d.id = r.workflow_def_id
    where d.name = 'release_vessel' order by r.created_at desc limit 1),
  'approve', '{"decision":"released","by":"crew"}'::jsonb);
-- /block
rollback to savepoint crew_signs;
\set ON_ERROR_STOP on
select pg_temp.check(:'LAST_ERROR_MESSAGE' like 'not authorized to signal run %',
    '§8 crew is refused at the signature: ' || :'LAST_ERROR_MESSAGE');
select pg_temp.check(pg_temp.status(current_setting('run.id')::uuid, 'approve') = 'waiting_external',
    '§8 and the step still waits');
-- The reader finds the run by its workflow's name, and says who they are before signing, as the published
-- first-workflow page does.
-- block: signal
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false);

select workflow.signal_task(
  (select r.id from workflow.runs r
     join workflow.definitions d on d.id = r.workflow_def_id
    where d.name = 'release_vessel' order by r.created_at desc limit 1),
  'approve', '{"decision":"released","by":"harbourmaster"}'::jsonb);
-- /block
select set_config('request.jwt.claims', '', false);
-- live: released
-- show $RUN
-- /live

select pg_temp.check((select status from workflow.runs where id = current_setting('run.id')::uuid) = 'succeeded',
    '§8 the signal finishes the run');

-- The same defect one function along: a run whose last step is a timer stayed `running` once it fired.
select workflow.define_yaml($y$
name: wait_then_stop
steps:
  - {id: wait, timer: 60}
$y$);

do $$
declare r uuid := pg_temp.start('wait_then_stop');
begin
    update workflow.tasks set run_after = now() where run_id = r;
    perform workflow.promote_due_timers();
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded',
        '§8 a timer that is the last step finishes the run');
end $$;


-- §9 ------------------------------------------------------------------------------------------------------------
-- block: berths
create table berth_holds    (run_id uuid, port text);
create table pilot_bookings (run_id uuid, vessel text);
grant select, insert, delete on berth_holds, pilot_bookings to authenticated;
-- /block

-- block: booking
select workflow.define_yaml($y$
name: booking
steps:
  - id: reserve_berth
    sql: {statement: "insert into berth_holds values ('{{run.$id}}'::uuid, 'Rotterdam')", write: true}
    compensate_with: release_berth
    saga_group: booking
  - id: book_pilot
    needs: [reserve_berth]
    sql: {statement: "insert into pilot_bookings values ('{{run.$id}}'::uuid, 'MERI')", write: true}
    compensate_with: cancel_pilot
    saga_group: booking
  - id: confirm
    needs: [book_pilot]
    sql: "select 1 / 0"          # the step that fails
    saga_group: booking
  - id: release_berth
    sql: {statement: "delete from berth_holds where run_id = '{{run.$id}}'::uuid", write: true}
  - id: cancel_pilot
    sql: {statement: "delete from pilot_bookings where run_id = '{{run.$id}}'::uuid", write: true}
$y$);
-- /block
-- live: start_booking
-- RUN=$(start booking '{}')
-- show $RUN
-- /live

do $$
declare r uuid := pg_temp.start('booking', '{}');
begin
    perform pg_temp.check((select status = 'failed' and compensation_state = 'compensated'
                             from workflow.runs where id = r), '§9 failed, and compensated');
    perform pg_temp.check((select count(*) from berth_holds) + (select count(*) from pilot_bookings) = 0,
        '§9 both writes are undone');
    perform pg_temp.check((select array_agg(split_part(step_key, ':', 1) order by completed_at)
                             from workflow.tasks where run_id = r and compensates_task_id is not null)
        = array['cancel_pilot', 'release_berth'], '§9 in reverse order');
end $$;


-- §11 -----------------------------------------------------------------------------------------------------------
-- block: claims
create table claims (id int primary key, policy_id text, approved boolean not null default false);
grant select, update on claims to authenticated;
insert into claims values (7, 'POL-1', false), (8, 'POL-2', false);

create function check_coverage(policy_id text) returns jsonb language sql
  as $$ select jsonb_build_object('policy', policy_id, 'covered', true) $$;
select 'check_coverage registered'
from workflow.register_step_function('check_coverage', 'public.check_coverage', array['text']);
-- /block

-- block: insurance_claim
select workflow.define_yaml($y$
name: insurance_claim
steps:
  - id: fraud
    agent: fraud_scorer
    input: 'Score the fraud risk of this claim from 0 (none) to 1 (certain): {{run.claim}}'
    output_schema:
      type: object
      required: [score]
      properties: {score: {type: number}}
  - id: coverage
    sql: {function: check_coverage, args: ['{{run.policy_id}}']}
  - id: documents
    agent: document_reviewer
    input: '{{run.documents}}'
  - id: assess
    needs: [fraud, coverage, documents]
    agent: assessor
    input: 'Fraud {{steps.fraud.result}}, cover {{steps.coverage.result}}, documents {{steps.documents.result}}'
  - id: adjuster
    needs: [assess, fraud]
    when: "{{steps.fraud.result.score}} > 0.5"
    signal: true
  - id: approve_payment
    needs: [adjuster]
    sql: {statement: "update claims set approved = true where id = {{run.claim_id}}", write: true}
    compensate_with: reverse_approval
    saga_group: payout
  - id: transfer
    needs: [approve_payment]
    queue: http
    rest:
      url: '{{env.BANK_API}}/transfers'
      method: POST
      credential_ref: BANK_TOKEN
      body: {claim: '{{run.claim_id}}'}
    saga_group: payout
  - id: reverse_approval
    sql: {statement: "update claims set approved = false where id = {{run.claim_id}}", write: true}
$y$);
-- /block
-- live: bank
-- cat > docker-compose.override.yml <<'EOF'
-- services:
--   worker:
--     environment:
--       P8_TEMPLATE_ENV: BANK_API
--       BANK_API: http://agent:8080/no-bank    # answers 404, so the payout is reversed
--       BANK_TOKEN: test-token
--       # a credential goes only where this binds it; the first entry is the compose default
--       P8_CREDENTIAL_ORIGINS: '{"LLM_API_KEY": ["https://api.openai.com"], "BANK_TOKEN": ["http://agent:8080"]}'
-- EOF
-- /live
-- live: worker
-- docker compose up -d worker
-- /live
-- live: start_insurance_claim
-- RUN=$(start insurance_claim '{"claim_id": 7, "policy_id": "POL-1", "documents": "survey.pdf, invoice.pdf", "claim": "Hull damage at berth 4."}')
-- /live

do $$
declare r uuid := pg_temp.start('insurance_claim',
    '{"claim_id": 7, "policy_id": "POL-1", "documents": "survey.pdf, invoice.pdf", "claim": "Hull damage at berth 4."}');
begin
    perform pg_temp.check(pg_temp.status(r, 'coverage') = 'succeeded', '§11 the coverage query ran in-database');
    perform pg_temp.check(pg_temp.work(r) = 2, '§11 fraud and documents start together');
    perform pg_temp.check(pg_temp.work(r) = 1, '§11 assess runs once all three are back');
    perform pg_temp.check(pg_temp.status(r, 'adjuster') = 'waiting_external', '§11 then the adjuster is waited for');
    perform set_config('run.id', r::text, true);
end $$;

-- live: adjuster_waiting
-- waiting $RUN adjuster
-- /live
-- block: adjuster
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false);

select workflow.signal_task(
  (select r.id from workflow.runs r
     join workflow.definitions d on d.id = r.workflow_def_id
    where d.name = 'insurance_claim' order by r.created_at desc limit 1),
  'adjuster', '{"decision": "approved"}');
-- /block
select set_config('request.jwt.claims', '', false);
-- live: claim_done
-- show $RUN
-- /live

do $$
declare r uuid := current_setting('run.id')::uuid;
begin
    perform pg_temp.check((select approved from claims where id = 7), '§11 the signal approves the payment');
    perform pg_temp.work(r);   -- the bank answers 404
    perform pg_temp.check((select status = 'failed' and compensation_state = 'compensated'
                             from workflow.runs where id = r), '§11 the payout saga compensated');
    perform pg_temp.check(not (select approved from claims where id = 7), '§11 the approval is reversed');
end $$;

-- A claim scored below the threshold skips the adjuster and goes straight to payment (REM-967).
do $$
declare r uuid := pg_temp.start('insurance_claim',
    '{"claim_id": 8, "policy_id": "POL-2", "documents": "survey.pdf", "claim": "A scraped fender."}');
begin
    perform pg_temp.check(pg_temp.work(r) = 2 and pg_temp.work(r) = 1, '§11 the low claim is checked and assessed');
    perform pg_temp.check(pg_temp.status(r, 'adjuster') = 'skipped', '§11 below 0.5 the adjuster is skipped');
    perform pg_temp.check(pg_temp.status(r, 'approve_payment') = 'succeeded', '§11 and the payment is approved at once');
end $$;


-- §10 -----------------------------------------------------------------------------------------------------------
-- The reader runs the trace from the shell, with $RUN (section 9's saga) and $SID (section 7's conversation).
-- live: trace
-- psql "$P8_DSN" -v run_id=$RUN -v session_id=$SID <<'SQL'
-- select step_key, kind, status, claimed_by as worker
-- from workflow.tasks
-- where run_id = :'run_id' order by step_key;
--
-- select seq, role, jsonb_array_length(tool_calls) as tool_calls, citations
-- from agentic.messages where session_id = :'session_id' order by seq;
-- SQL
-- /live
select current_setting('run.id') as run_id, current_setting('session.id') as session_id \gset
select step_key, kind, status, claimed_by as worker from workflow.tasks where run_id = :'run_id' order by step_key;
select seq, role, jsonb_array_length(tool_calls) as tool_calls, citations
from agentic.messages where session_id = :'session_id' order by seq;

select pg_temp.check((select count(*) from workflow.tasks where run_id = current_setting('run.id')::uuid) = 8,
    '§10 every step of the claim, the reversal included, is a row');

-- One question across the fleet, the conversations and the runs.
-- block: cross
select v.name, b.port,
       count(distinct m.session_id) as conversations,
       count(distinct t.run_id)     as runs
  from fleet.port_calls c
  join fleet.vessels v on v.id = c.vessel_id
  join fleet.berths  b on b.id = c.berth_id
  left join agentic.messages_api m on strpos(m.content, v.name) > 0
  left join workflow.tasks_api   t on strpos(t.output::text, v.name) > 0
 where c.departed_at is null
 group by v.name, b.port order by v.name;
-- /block
-- live: cross_curl
-- curl -s $REST/rpc/sql_passthrough \
--   -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
--   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"p_statement": "select v.name, b.port, count(distinct m.session_id) as conversations, count(distinct t.run_id) as runs from fleet.port_calls c join fleet.vessels v on v.id = c.vessel_id join fleet.berths b on b.id = c.berth_id left join agentic.messages_api m on strpos(m.content, v.name) > 0 left join workflow.tasks_api t on strpos(t.output::text, v.name) > 0 where c.departed_at is null group by v.name, b.port order by v.name"}'; echo
-- /live


rollback;
