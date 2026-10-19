-- THE LANGGRAPH ARTICLE RUNS, BLOCK FOR BLOCK (REM-957).
--
-- "Percolate for LangGraph Users" (Percolate writing ld-83cdc18c9991) was drafted from the 0.2.22 docs and never
-- run. Run on 0.2.23 it failed in four places: the saga and the worked example did not compile (`compensate_with`
-- named steps that did not exist), the waiting fragment needed a step it did not show, and `session_group` never
-- shared a conversation with the real runtime. specs/design/core-product.md §1 says an article is a test, so this
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
-- `-- /live` where the article has them, each line behind "-- ". The live run takes each out, drops that prefix,
-- and runs it as the reader would, in one shell whose variables and functions carry from block to block, with the
-- SQL in one psql session. It changes only what this machine forces: the project and directory name, the ports in
-- the stack's .env (and the content and MinIO ports, taken here too), the image (a local 0.2.23 build until
-- percolationlabs/percolate-postgres:19-0.2.23 is published), and the model. dev/faultsrv
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
                case when t.step_key = 'fraud' then '{"score": 0.12}'::jsonb
                     when t.step_key = 'plan'  then '{"sections": ["intro", "method", "results"]}'::jsonb
                     else to_jsonb('answer from ' || t.step_key) end), 'wf25');
        end if;
    end loop;
    return v_n;
end $$ language plpgsql;

create function pg_temp.status(p_run uuid, p_step text) returns text as $$
    select status from workflow.tasks where run_id = p_run and step_key = p_step
$$ language sql;


-- Before you start -----------------------------------------------------------------------------------------------
-- live: stack
-- # Percolate: the stack, get-percolate's compose file, in a project of its own
-- mkdir langgraph-tour && cd langgraph-tour
-- curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml \
--   -o docker-compose.yml
-- sed -i.bak 's#percolationlabs/percolate-postgres:19-0.2.22#percolationlabs/percolate-postgres:19-0.2.23#' \
--   docker-compose.yml
-- cat > .env <<'EOF'
-- COMPOSE_PROJECT_NAME=langgraph-tour
-- P8_PG_PORT=5432
-- P8_REST_PORT=3000
-- P8_AGENT_PORT=8080
-- OPENAI_API_KEY=sk-your-key
-- EOF
-- docker compose up -d --wait
-- /live
-- live: shell
-- # Percolate: the shell, in the same directory. The CLI needs Python 3.11 or newer; jq is for start.
-- python3 -m venv .venv && . .venv/bin/activate
-- pip install 'percolate-core[sample,agent]>=0.2.5'
--
-- set -a; . ./.env; set +a
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
-- start() {   # start <workflow> '<input as JSON>' prints the run id
--   curl -s $REST/rpc/start_workflow \
--     -H 'Content-Profile: workflow' -H "Authorization: Bearer $TOKEN" \
--     -H 'Content-Type: application/json' \
--     -d "{\"p_name\": \"$1\", \"p_input\": $2}" | jq -r .
-- }
--
-- show() {    # show <run id> waits up to a minute for the run to settle, then prints it
--   for i in $(seq 30); do
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
-- waiting() { # waiting <run id> <step> waits up to a minute for the step to need a person, then prints its status
--   for i in $(seq 30); do
--     s=$(psql "$P8_DSN" -Atc "select status from workflow.tasks where run_id = '$1' and step_key = '$2'")
--     case $s in waiting_external|succeeded|failed|cancelled) break ;; esac
--     sleep 2
--   done
--   echo "$s"
-- }
-- /live


-- §1 ------------------------------------------------------------------------------------------------------------
-- live: harbourmaster.yaml
-- # Percolate: harbourmaster.yaml
-- type: object
-- name: harbourmaster
-- description: |-
--   You answer questions about the fleet.
--   Start with SCHEMA to see what exists, then query. Never guess a vessel name.
-- model: openai:gpt-4o-mini
-- tools:
--   - server: harbour-query
--     tools: [query]
-- properties:
--   verdict: {type: string}
--   vessel:  {type: string}
-- required: [verdict, vessel]
-- /live
-- block: tool-server
select (agentic.upsert_tool_server($j${
  "name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090"
}$j$::jsonb)).name;
-- /block

select pg_temp.check(exists (select 1 from agentic.tool_servers where name = 'harbour-query'),
    '§1 the tool server is a row');
-- live: push
-- percolate agent push harbourmaster.yaml
-- /live
-- live: chat
-- curl -s -X POST $AGENT/tools/harbour-query/sync -H "Authorization: Bearer $TOKEN"; echo
--
-- curl -sN $AGENT/chat -D headers.txt \
--   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"model": "harbourmaster", "stream": true,
--        "messages": [{"role": "user", "content": "Which vessels exist?"}]}'
-- /live


-- §2 ------------------------------------------------------------------------------------------------------------
-- The agents every workflow below names. The draft used them and never made them; define_yaml only warns.
-- block: agents
select (agentic.upsert_agent(jsonb_build_object(
         'name', a, 'model', 'openai:gpt-4o-mini',
         'system_prompt', 'You are the ' || replace(a, '_', ' ') || '. Answer briefly.'))).name
from unnest(array['joker', 'writer', 'editor', 'planner', 'psc_report_extractor', 'classifier',
                  'researcher', 'fraud_scorer', 'document_reviewer', 'assessor']) a;
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
    agent: joker
    input: 'Make this funnier with wordplay: {{steps.generate.result}}'
  - id: polish
    needs: [improve]
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
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded', '§2 the chain finishes');
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
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded'
        and (select output #>> '{result,0,n}' from workflow.tasks where run_id = r and step_key = 'b') = '2',
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

do $$
declare r uuid := pg_temp.start('compare', '{"topic": "tides"}');
begin
    perform pg_temp.check(pg_temp.work(r) = 3, '§3 three steps with no dependency start together');
    perform pg_temp.check(pg_temp.work(r) = 1, '§3 the join runs once all three are back');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded', '§3 the run finishes');
end $$;


-- §4 ------------------------------------------------------------------------------------------------------------
-- The writers are made here rather than pushed: the runtime lists agents nobody owns, and `percolate agent push`
-- makes an agent its pusher's own (see the card linked from the article).
-- block: router
select (agentic.upsert_tool_server($j${
  "name": "p8-agents", "kind": "mcp",
  "url": "http://agent:8080/mcp", "serves_agents": true
}$j$::jsonb)).name;

select (agentic.upsert_agent(jsonb_build_object('name', w, 'model', 'openai:gpt-4o-mini',
         'system_prompt', 'Write a short ' || w || ' about what you are given.'))).name
from unnest(array['story', 'joke', 'poem']) w;

select (agentic.upsert_agent($j${
  "name": "router", "model": "openai:gpt-4o-mini",
  "system_prompt": "Hand the request to the story, joke or poem writer.",
  "tools": [{"server": "p8-agents",
             "tools": ["agent__story", "agent__joke", "agent__poem"]}]
}$j$::jsonb)).name;
-- /block

-- live: sync
-- curl -s -X POST $AGENT/tools/p8-agents/sync \
--   -H "Authorization: Bearer $TOKEN"; echo
-- /live
-- live: router_chat
-- curl -sN $AGENT/chat -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
--   -d '{"model": "router", "stream": true,
--        "messages": [{"role": "user", "content": "Tell me a story about tides."}]}'
-- /live

select pg_temp.check((select tools from agentic.agents where name = 'router')
    = '[{"server": "p8-agents", "tools": ["agent__story", "agent__joke", "agent__poem"]}]', '§4 the allowlist is a row');


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
                            where run_id = r and step_key = 'land') = '3', '§5 the fan-in lands every child');
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
        = array['intro', 'method', 'results'], '§5 each child got its section');
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
    perform pg_temp.check((v_ctx #>> '{task_input,body,session_id}')::uuid = v_sid,
        '§7 the step sends the group''s session as session_id');
    perform pg_temp.check(exists (select 1 from agentic.sessions where id = v_sid
                                   and owner_id = (select id from rbac.users where email = 'me@example.com')),
        '§7 the session row exists, owned by the person who started the run');
    perform workflow.complete_task(t.id, '{"status": 200, "result": "safety"}', 'wf25');

    select * into t from workflow.claim_task('http', 'wf25') where run_id = r;
    v_ctx := workflow.get_task_context(t.id, 'wf25');
    perform pg_temp.check(t.step_key = 'deep_dive'
        and (v_ctx #>> '{task_input,body,session_id}')::uuid = v_sid, '§7 both steps carry one session');
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
-- The reader finds the run by its workflow's name, and says who they are before signing, as the published
-- first-workflow page does.
-- block: signal
select r.id as run_id from workflow.runs r
  join workflow.definitions d on d.id = r.workflow_def_id
 where d.name = 'release_vessel' order by r.created_at desc limit 1 \gset

select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false);

select workflow.signal_task(:'run_id', 'approve',
  '{"decision":"released","by":"harbourmaster"}'::jsonb);
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
insert into claims values (7, 'POL-1', false);

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
    input: '{{run.claim}}'
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
    needs: [assess]
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
-- # Percolate: docker-compose.override.yml, beside docker-compose.yml
-- services:
--   worker:
--     environment:
--       P8_TEMPLATE_ENV: BANK_API
--       BANK_API: http://agent:8080/no-bank    # answers 404, so the payout is reversed
--       BANK_TOKEN: test-token
--       # a credential goes only where this binds it; the first entry is the compose default
--       P8_CREDENTIAL_ORIGINS: '{"LLM_API_KEY": ["https://api.openai.com"], "BANK_TOKEN": ["http://agent:8080"]}'
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
select r.id as run_id from workflow.runs r
  join workflow.definitions d on d.id = r.workflow_def_id
 where d.name = 'insurance_claim' order by r.created_at desc limit 1 \gset

select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false);

select workflow.signal_task(:'run_id', 'adjuster', '{"decision": "approved"}');
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


-- §10 -----------------------------------------------------------------------------------------------------------
-- The reader runs the trace from the shell, with $RUN (section 9's saga) and $SID (section 7's conversation).
-- live: trace
-- psql "$P8_DSN" -v run_id=$RUN -v session_id=$SID <<'SQL'
-- select step_key, kind, status, claimed_by as worker
-- from workflow.tasks
-- where run_id = :'run_id' order by step_key;
--
-- select seq, role, citations from agentic.messages
-- where session_id = :'session_id' order by seq;
-- SQL
-- /live
select current_setting('run.id') as run_id, current_setting('session.id') as session_id \gset
select step_key, kind, status, claimed_by as worker from workflow.tasks where run_id = :'run_id' order by step_key;
select seq, role, citations from agentic.messages where session_id = :'session_id' order by seq;

select pg_temp.check((select count(*) from workflow.tasks where run_id = current_setting('run.id')::uuid) = 8,
    '§10 every step of the claim, the reversal included, is a row');

rollback;
