-- A SCHEDULED AGENT STEP IS CHECKED WHERE IT CARRIES ITS AGENT.
--
-- workflow-engine/README.md, "Delegation", documents the scheduled step: an
-- http_call in mode async posting to {{env.P8_AGENT_URL}}/internal/run, with the
-- agent named in body.input.agent. lint_spec read body.model for every url
-- containing P8_AGENT_URL, so that step drew `agent step names NULL, which is
-- not in agentic.agents` whatever agent it named, and plan_probe failed it the
-- same way. An `agent:` step that names no agent must still warn.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

do $$
declare
    -- The documented step, verbatim, and the step it depends on.
    v_judge jsonb := $j${
        "key": "judge",
        "kind": "http_call",
        "input": {
            "url": "{{env.P8_AGENT_URL}}/internal/run",
            "body": {
                "workflow_task_id": "{{task.id}}",
                "input": {
                    "agent": "classifier",
                    "prompt": "Classify this - {{steps.retrieve.result}}"
                }
            },
            "method": "POST",
            "mode": "async",
            "timeout_ms": 120000,
            "credential_ref": "P8_API_KEY"
        },
        "queue": "http",
        "depends_on": ["retrieve"]
    }$j$;
    v_retrieve jsonb := '{"key":"retrieve","kind":"sql","queue":"none",
                          "input":{"function":"p8ql","args":["SCHEMA"]}}';
    v_found text;
    v_row   record;
begin
    if to_regclass('agentic.agents') is null then
        raise exception 'workflow/22: agentic.agents is absent, so the agent check '
                        'this file tests never runs';
    end if;
    if not exists (select 1 from agentic.agents where name = 'classifier') then
        insert into agentic.agents (name) values ('classifier');
    end if;

    -- 1. The documented scheduled step, naming a registered agent: no warning.
    select string_agg(severity || ': ' || detail, '; ') into v_found
      from workflow.lint_spec(jsonb_build_object('steps', jsonb_build_array(v_retrieve, v_judge)))
     where severity in ('warning', 'error');
    if v_found is not null then
        raise exception 'workflow/22: the documented scheduled step drew %', v_found;
    end if;

    -- 2. The same step naming an agent with no row warns, and names THAT agent,
    -- so the check reads body.input.agent rather than skipping the step.
    select string_agg(detail, '; ') into v_found
      from workflow.lint_spec(jsonb_build_object('steps', jsonb_build_array(v_retrieve,
             jsonb_set(v_judge, '{input,body,input,agent}', '"t22_no_such_agent"'))))
     where severity = 'warning';
    if v_found is null or v_found not like 'agent step names ''t22_no_such_agent''%' then
        raise exception 'workflow/22: a scheduled step naming an unregistered agent drew %',
            coalesce(v_found, 'no warning');
    end if;

    -- 3. An `agent:` step as the compiler emits it, with no agent in body.model,
    -- still warns.
    select string_agg(detail, '; ') into v_found
      from workflow.lint_spec($j${"steps":[{"key":"ask","kind":"http_call","queue":"http",
             "input":{"url":"{{env.P8_AGENT_URL}}/v1/chat/completions","method":"POST",
                      "body":{"messages":[{"role":"user","content":"hello"}]}}}]}$j$::jsonb)
     where severity = 'warning';
    if v_found is null or v_found not like 'agent step names NULL%' then
        raise exception 'workflow/22: an agent: step naming no agent drew %',
            coalesce(v_found, 'no warning');
    end if;

    -- 4. plan_probe reads the same place: the documented step's agent exists.
    insert into workflow.definitions (name, spec)
    values ('t22_scheduled', jsonb_build_object('steps', jsonb_build_array(v_retrieve, v_judge)));
    select * into v_row from workflow.plan_probe('t22_scheduled')
     where step = 'judge' and probe = 'agent';
    if v_row.verdict is distinct from 'ok' then
        raise exception 'workflow/22: plan_probe gave the documented step % (%)',
            coalesce(v_row.verdict, 'no agent probe'), v_row.detail;
    end if;

    raise notice 'workflow/22: a scheduled step is checked by the agent it names';
end $$;

rollback;
