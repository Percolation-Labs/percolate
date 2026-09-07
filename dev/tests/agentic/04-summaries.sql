-- CONTEXT COMPACTION, EXERCISED. `agentic.upsert_summary`,
-- `agentic.apply_summary` and `agentic.channel_for` were three of the
-- twenty-three promises `agentic` makes that
-- nothing called by name -- found by asking the self-model which subsystem had
-- the most unchecked claims, not by reading the schema.
--
-- Compaction is the mechanism that lets a long conversation stay inside a
-- context window, so its characteristic failure is a WRONG ANSWER rather than
-- an error: a summary written to the wrong session, or a second summary row
-- where the design promises one, and every later turn quietly reads the wrong
-- history.
\set ON_ERROR_STOP on
begin;
set local role app_owner;

create temp table t_ctx (u1 uuid, u2 uuid, s1 uuid, s2 uuid);
insert into t_ctx values (gen_random_uuid(), gen_random_uuid(), null, null);

do $$
declare c t_ctx%rowtype;
begin
    select * into c from t_ctx;
    insert into rbac.users (id, email) values
        (c.u1, 'sum-a@t'), (c.u2, 'sum-b@t') on conflict do nothing;

    -- Sessions are created AS the caller: agentic.sessions.owner_id comes from
    -- the claims, so the fixture has to wear the identity rather than set the
    -- column.
    perform set_config('request.jwt.claims', json_build_object('sub', c.u1)::text, true);
    insert into agentic.sessions (owner_id) values (c.u1) returning id into c.s1;
    perform set_config('request.jwt.claims', json_build_object('sub', c.u2)::text, true);
    insert into agentic.sessions (owner_id) values (c.u2) returning id into c.s2;
    update t_ctx set s1 = c.s1, s2 = c.s2;
end $$;

-- 1. A summary is written, and re-writing REPLACES rather than accumulates.
--    This is the promise the partial unique index carries, and the one a
--    rolling summary depends on: compaction that appends is not compaction.
do $$
declare c t_ctx%rowtype; n int;
begin
    select * into c from t_ctx;
    perform set_config('request.jwt.claims', json_build_object('sub', c.u1)::text, true);

    perform agentic.upsert_summary(c.s1, 'first summary');
    perform agentic.upsert_summary(c.s1, 'second summary');

    select count(*) into n from agentic.messages
     where session_id = c.s1 and role = 'summary';
    if n <> 1 then
        raise exception 'compaction accumulated: % summary rows for one session, expected 1', n;
    end if;

    -- `is distinct from`, not `<>`. With no summary row the subquery is NULL,
    -- `NULL <> 'x'` is NULL, and `if NULL then` does not fire -- so the
    -- assertion would pass precisely when the row it checks is absent.
    -- dev/assertion-audit.py caught all three of these, which is the gate
    -- this collection built for exactly this shape.
    if (select content from agentic.messages
         where session_id = c.s1 and role = 'summary') is distinct from 'second summary' then
        raise exception 'the rolling summary did not roll: the first write survived';
    end if;
end $$;

-- 2. A summary belongs to ITS session. The failure this guards is the quiet
--    one: a caller compacting somebody else's conversation.
do $$
declare c t_ctx%rowtype;
begin
    select * into c from t_ctx;
    perform set_config('request.jwt.claims', json_build_object('sub', c.u1)::text, true);
    begin
        perform agentic.upsert_summary(c.s2, 'not mine to write');
        raise exception 'a caller summarised a session that is not theirs';
    exception when others then
        if position('not yours' in sqlerrm) = 0 then raise; end if;
    end;
end $$;

-- 3. channel_for is stable and session-scoped -- a client subscribing to the
--    wrong channel sees somebody else's turns, which is a tenancy bug wearing
--    a transport costume.
do $$
declare c t_ctx%rowtype; a text; b text;
begin
    select * into c from t_ctx;
    a := agentic.channel_for(c.s1);
    b := agentic.channel_for(c.s1);
    if a is distinct from b then
        raise exception 'channel_for is not stable: % then %', a, b;
    end if;
    if a = agentic.channel_for(c.s2) then
        raise exception 'two sessions share a notify channel (%)', a;
    end if;
end $$;

-- 4. apply_summary is the workflow-facing wrapper, and its whole job is a
--    GUARD: only a scheduled run writes. A summariser reached by delegation
--    is producing a tool result for its caller, and if that output landed in
--    the session's rolling summary it would silently overwrite the real one
--    with an answer to somebody's sub-question.
--
--    This assertion exists because the graph asked for it. The first version
--    of this file named apply_summary in its header comment and never called
--    it, and the `checks` edge -- which needs the QUALIFIED symbol in the body
--    -- correctly refused to count a mention in a comment as coverage.
do $$
declare c t_ctx%rowtype; r jsonb;
begin
    select * into c from t_ctx;
    perform set_config('request.jwt.claims', json_build_object('sub', c.u1)::text, true);
    perform agentic.upsert_summary(c.s1, 'the real rolling summary');

    -- A delegated run. Must not write.
    r := agentic.apply_summary(jsonb_build_object(
            'trigger_kind', 'delegated',
            'session_id',   c.s1::text,
            'output',       jsonb_build_object('summary', 'a sub-answer')));
    if r->>'skipped' is null then
        raise exception 'agentic.apply_summary wrote on a non-scheduled run: %', r;
    end if;
    -- `is distinct from`, not `<>`. With no summary row the subquery is NULL,
    -- `NULL <> 'x'` is NULL, and `if NULL then` does not fire -- so the
    -- assertion would pass precisely when the row it checks is absent.
    -- dev/assertion-audit.py caught all three of these, which is the gate
    -- this collection built for exactly this shape.
    if (select content from agentic.messages
         where session_id = c.s1 and role = 'summary') is distinct from 'the real rolling summary' then
        raise exception 'a delegated run overwrote the rolling summary';
    end if;

    -- The scheduled run must write, or the guard is just an off switch.
    r := agentic.apply_summary(jsonb_build_object(
            'trigger_kind', 'scheduled',
            'session_id',   c.s1::text,
            'output',       jsonb_build_object('summary', 'compacted')));
    if r->>'skipped' is not null then
        raise exception 'agentic.apply_summary skipped a scheduled run: %', r;
    end if;
    -- `is distinct from`, not `<>`. With no summary row the subquery is NULL,
    -- `NULL <> 'x'` is NULL, and `if NULL then` does not fire -- so the
    -- assertion would pass precisely when the row it checks is absent.
    -- dev/assertion-audit.py caught all three of these, which is the gate
    -- this collection built for exactly this shape.
    if (select content from agentic.messages
         where session_id = c.s1 and role = 'summary') is distinct from 'compacted' then
        raise exception 'a scheduled run did not write the summary';
    end if;
end $$;

\echo '  04-summaries.sql                   ok'
rollback;
