-- THE CONVERSATION PLANE, EXECUTED.
--
-- The claims audit found this whole path declared and untested: create_session,
-- start_run, persist_turn, finish_run and the two skill statements were present
-- in `surface.sql`, cited to brief.md, and called by nothing in this suite. It
-- is the subsystem's largest gap and the one place a defect is invisible from
-- the outside -- a turn that persists wrongly still returns rows.
--
-- Each section asserts a sentence the brief actually makes, rather than the
-- shape of the code underneath it.
\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- A caller identity, because every one of these functions is scoped by
-- rbac.current_user_id() and the interesting failures are about ownership.
insert into rbac.users (id, email, status)
values ('c1a11111-0000-0000-0000-00000000c001', 'turn-owner@example.com', 'active'),
       ('c1a22222-0000-0000-0000-00000000c002', 'someone-else@example.com', 'active')
on conflict (id) do nothing;

-- The caller is given the authoring permissions the guards actually ask for,
-- rather than the test reaching around them. `agentic.may_author` gates skills
-- and agents on <resource>/update, and a test that bypassed that would not be
-- exercising the path the runtime takes.
insert into rbac.roles (name, description) values ('conv_probe_author', 'test fixture')
on conflict (name) do nothing;
insert into rbac.role_permissions (role, resource, action)
select 'conv_probe_author', resource, action
  from rbac.permission_kinds where resource in ('agents','skills')
on conflict do nothing;
insert into rbac.user_roles (user_id, role)
values ('c1a11111-0000-0000-0000-00000000c001', 'conv_probe_author')
on conflict do nothing;

-- Written as that author, and public, because §5 edits it as them: an author
-- changes only the agents they own (REM-1067), and an operator-written agent
-- is nobody's.
set local request.jwt.claims = '{"sub":"c1a11111-0000-0000-0000-00000000c001"}';
select agentic.upsert_agent($j${"name": "conv_probe", "system_prompt": "a probe", "visibility": "public"}$j$::jsonb);
reset request.jwt.claims;

-- ---------------------------------------------------------------------
-- 1. A SESSION, A RUN, AND THE SPAN TREE DELEGATION CARRIES.
--
-- brief.md §3: a delegated run is a child, and the trace is the thing that
-- makes a delegation legible afterwards. A parent link that is not stored is a
-- conversation whose shape cannot be reconstructed.
-- ---------------------------------------------------------------------
do $$
declare v_s agentic.sessions; v_parent agentic.runs; v_child agentic.runs;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a11111-0000-0000-0000-00000000c001"}');

    v_s := agentic.create_session('a probe conversation');
    if v_s.id is null then raise exception 'create_session returned no session'; end if;
    if v_s.owner_id <> 'c1a11111-0000-0000-0000-00000000c001'::uuid then
        raise exception 'a session was created owned by % rather than its caller', v_s.owner_id;
    end if;

    v_parent := agentic.start_run('conv_probe', v_s.id, null, null, 'trace-conv-1');
    v_child  := agentic.start_run('conv_probe', v_s.id, v_parent.id, null, 'trace-conv-1');

    if v_child.parent_run_id is distinct from v_parent.id then
        raise exception 'a delegated run did not record its parent (% vs %)',
            v_child.parent_run_id, v_parent.id;
    end if;
    if v_child.trace_id is distinct from v_parent.trace_id then
        raise exception 'a delegated run left the parent trace (% vs %)',
            v_child.trace_id, v_parent.trace_id;
    end if;
    raise notice 'agentic/02: a delegated run is a child of its delegator and stays in its trace';
end $$;

-- ---------------------------------------------------------------------
-- 2. ONE CALL PER TURN, AND THE ID THE RUNTIME ALREADY STREAMED.
--
-- brief.md §4. The assistant row's id is minted by the runtime BEFORE the turn
-- runs, so its streamed deltas and this row are the same message. A database
-- that assigns its own id instead breaks the stream silently -- the client is
-- left holding deltas for a message id that never existed. And `seq` must
-- follow conversation order, not planner order.
-- ---------------------------------------------------------------------
do $$
declare
    v_s agentic.sessions; v_run agentic.runs;
    v_mine uuid := 'aaaa1111-0000-0000-0000-0000000000aa';
    v_n int; v_first text; v_seq_ok boolean;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a11111-0000-0000-0000-00000000c001"}');
    v_s   := agentic.create_session('turn ordering');
    v_run := agentic.start_run('conv_probe', v_s.id);

    perform agentic.persist_turn(jsonb_build_array(
        jsonb_build_object('run_id', v_run.id, 'session_id', v_s.id,
                           'role', 'user',      'content', 'the question'),
        jsonb_build_object('run_id', v_run.id, 'session_id', v_s.id,
                           'id', v_mine,
                           'role', 'assistant', 'content', 'the answer')));

    select count(*) into v_n from agentic.messages where run_id = v_run.id;
    if v_n <> 2 then raise exception 'one turn wrote % rows, expected 2', v_n; end if;

    if not exists (select 1 from agentic.messages where id = v_mine) then
        raise exception 'persist_turn discarded the caller-supplied message id -- '
                        'the streamed deltas now refer to a message that does not exist';
    end if;

    select role into v_first from agentic.messages
     where run_id = v_run.id order by seq limit 1;
    if v_first is distinct from 'user' then
        raise exception 'seq did not follow conversation order: first row is %', v_first;
    end if;
    raise notice 'agentic/02: a turn is one call, the runtime keeps the id it streamed, and seq follows the conversation';
end $$;

-- ---------------------------------------------------------------------
-- 3. A RUN THAT IS NOT YOURS IS NOT WRITEABLE.
--
-- The refusal is the point. Without it, knowing a run's uuid is enough to
-- append to somebody else's conversation, and the row would look native.
-- ---------------------------------------------------------------------
do $$
declare v_s agentic.sessions; v_run agentic.runs; v_refused boolean := false;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a11111-0000-0000-0000-00000000c001"}');
    v_s   := agentic.create_session('mine');
    v_run := agentic.start_run('conv_probe', v_s.id);

    -- now somebody else, holding the uuid
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a22222-0000-0000-0000-00000000c002"}');
    begin
        perform agentic.persist_turn(jsonb_build_array(jsonb_build_object(
            'run_id', v_run.id, 'session_id', v_s.id,
            'role', 'assistant', 'content', 'injected')));
    exception when others then
        v_refused := sqlerrm like '%not yours%';
    end;
    if not v_refused then
        raise exception 'another user appended a message to a run they do not own';
    end if;
    raise notice 'agentic/02: holding a run id is not authority to write into it';
end $$;

-- ...AND NEITHER IS A SESSION'S.
--
-- The check above looked only at run_id, so a row naming somebody else's
-- session and no run -- a summary, the one role allowed to be runless, and the
-- one read back into the next turn's context -- went straight in. Measured
-- before persist_turn learned to refuse it: bob's summary landed in alice's
-- private session and alice read it back (REM-46). The owner writing into her
-- own session is §2 above.
do $$
declare v_s agentic.sessions; v_refused text; v_n int;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a11111-0000-0000-0000-00000000c001"}');
    v_s := agentic.create_session('mine, and nobody else''s');

    execute format('set local request.jwt.claims = %L', '{"sub":"c1a22222-0000-0000-0000-00000000c002"}');
    begin
        perform agentic.persist_turn(jsonb_build_array(jsonb_build_object(
            'session_id', v_s.id, 'role', 'summary', 'content', 'planted')));
    exception when others then
        v_refused := sqlerrm;
    end;
    select count(*) into v_n from agentic.messages where session_id = v_s.id;
    if v_n <> 0 then
        raise exception 'another user wrote % message(s) into a session they do not own', v_n;
    end if;
    if v_refused is null or v_refused not like '%session that is not yours%' then
        raise exception 'the write into another user''s session was not refused for that reason: %',
            coalesce(v_refused, 'it was not refused');
    end if;
    raise notice 'agentic/02: holding a session id is not authority to write into it';
end $$;

-- ---------------------------------------------------------------------
-- 4. finish_run RECORDS THE OUTCOME.
--
-- `succeeded`, not `completed`. workflow.runs and agentic.runs are both called
-- `runs`, both carry a constraint named `runs_status_check`, and they disagree
-- about the word for the terminal state -- workflow says completed, agentic
-- says succeeded. Writing this test against the wrong one is how that was
-- found, and the name is pinned here so the next person meets it as an
-- assertion rather than as a check-constraint violation.
-- ---------------------------------------------------------------------
do $$
declare v_s agentic.sessions; v_run agentic.runs; v_done agentic.runs;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a11111-0000-0000-0000-00000000c001"}');
    v_s   := agentic.create_session('finishing');
    v_run := agentic.start_run('conv_probe', v_s.id);
    v_done := agentic.finish_run(v_run.id, 'succeeded');
    if v_done.status <> 'succeeded' then
        raise exception 'finish_run left the run at %', v_done.status;
    end if;
    if v_done.finished_at is null then
        raise exception 'a finished run has no finished_at';
    end if;
    raise notice 'agentic/02: finish_run records the outcome and when it happened';
end $$;

-- ---------------------------------------------------------------------
-- 5. ATTACHING A SKILL IS ONE STATEMENT, AND IT DOES NOT INVENT AN AGENT.
--
-- plugins.md §5.5. Read-modify-write is what this replaces, so the test that
-- matters is that two attaches do not lose one another -- the lost-update the
-- single statement exists to prevent.
-- ---------------------------------------------------------------------
do $$
declare v_ag agentic.agents; v_refused boolean := false; v_before int;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a11111-0000-0000-0000-00000000c001"}');
    -- kebab-case: skills_name_check demands it, while agents next door accept
    -- snake_case. Two sibling objects in one schema with different naming rules
    -- is a trap the audit surfaced by making this test fail on its first run.
    perform agentic.upsert_skill($j${"name": "probe-skill-a", "description": "probe a", "content": "do a"}$j$::jsonb);
    perform agentic.upsert_skill($j${"name": "probe-skill-b", "description": "probe b", "content": "do b"}$j$::jsonb);

    perform agentic.attach_skill('conv_probe', 'probe-skill-a');
    v_ag := agentic.attach_skill('conv_probe', 'probe-skill-b');
    if not (v_ag.skills @> array['probe-skill-a','probe-skill-b']) then
        raise exception 'the second attach lost the first: %', v_ag.skills;
    end if;

    v_ag := agentic.detach_skill('conv_probe', 'probe-skill-a');
    if v_ag.skills @> array['probe-skill-a'] then
        raise exception 'detach_skill left the skill attached: %', v_ag.skills;
    end if;

    -- Attaching to an agent that does not exist must refuse, not create one.
    select count(*) into v_before from agentic.agents;
    begin
        perform agentic.attach_skill('no_such_agent_here', 'probe-skill-b');
    exception when others then
        v_refused := true;
    end;
    if not v_refused then
        raise exception 'attach_skill accepted an agent that does not exist';
    end if;
    if (select count(*) from agentic.agents) <> v_before then
        raise exception 'a failed attach created an agent';
    end if;
    raise notice 'agentic/02: attaches compose, detach removes, and neither invents an agent';
end $$;

-- ---------------------------------------------------------------------
-- 6. ...AND A CALLER WHO MAY NOT AUTHOR AGENTS IS REFUSED BEFORE ANYTHING ELSE.
--
-- Both functions looked the agent up first, so a caller with no agents:update
-- heard "no agent named %" for a name that does not exist and a different
-- refusal for one that does: which agents exist, answered to anybody, the
-- probe 2e5995e closed in may_invoke (REM-46). The refusal has to be the same
-- sentence either way. §5 above is the author being served.
-- ---------------------------------------------------------------------
do $$
declare v_msg text; f text; a text;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"c1a22222-0000-0000-0000-00000000c002"}');
    if rbac.has_permission('c1a22222-0000-0000-0000-00000000c002', 'agents', 'update') then
        raise exception 'the second fixture user holds agents:update -- this needs one who does not';
    end if;
    foreach f in array array['attach', 'detach'] loop
        foreach a in array array['conv_probe', 'no_such_agent_here'] loop
            v_msg := null;
            begin
                if f = 'attach' then perform agentic.attach_skill(a, 'probe-skill-b');
                else                 perform agentic.detach_skill(a, 'probe-skill-b');
                end if;
            exception when others then
                v_msg := sqlerrm;
            end;
            if v_msg is distinct from 'not authorized to author agents' then
                raise exception '%_skill(%) by a caller who may not author agents answered: %',
                    f, a, coalesce(v_msg, 'nothing -- it succeeded');
            end if;
        end loop;
    end loop;
    raise notice 'agentic/02: attach and detach refuse a non-author the same way whether or not the agent exists';
end $$;

rollback;
