-- THE ESCAPE HATCH -- the one function in this collection that runs SQL the
-- caller wrote.
--
-- `ai-query-layer/brief.md` §3 spends a paragraph correcting this function
-- from SECURITY DEFINER to SECURITY INVOKER, and says plainly what the wrong
-- answer would have been: "arbitrary caller SQL executing as the function
-- owner, i.e. an RLS bypass and privilege escalation primitive." That
-- correction was reasoned, written down, and never executed. This file
-- executes it.
--
-- The characteristic failure here is not a wrong answer and not a partial
-- success. It is a caller doing something the function was built to prevent,
-- with the function reporting success -- so every assertion below is an
-- attempt, and the pass condition is a refusal.
--
-- Two boundaries exist and only one of them is real, which the function's own
-- comment states: the leading-keyword regex is "a courtesy, NOT the security
-- boundary -- the read-only transaction below is." A test that only tried
-- `insert into ...` would exercise the courtesy and conclude the boundary
-- works. So most of what follows is deliberately written to walk PAST the
-- regex.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

create table t_sp_target (id int primary key, v text);
insert into t_sp_target values (1, 'before');
grant select, insert, update, delete on t_sp_target to authenticated;

-- ---------------------------------------------------------------------
-- 1. EVERY WRITE SHAPE IS REFUSED, INCLUDING THE ONES THE REGEX MISSES.
--
-- The regex anchors on the first keyword. Four of the six statements below do
-- not start with one of those keywords, and one of them (`explain analyze
-- insert`) really does execute its insert in ordinary Postgres. If the
-- read-only transaction ever stopped being set, this section is what notices.
-- ---------------------------------------------------------------------
do $$
declare
    v_attempts text[] := array[
        -- caught by the courtesy
        'insert into t_sp_target values (2, ''direct'')',
        'update t_sp_target set v = ''x''',
        'delete from t_sp_target',
        'create table t_sp_sneak (id int)',
        -- past the courtesy: these start with `with`, `select` or `explain`
        'with w as (insert into t_sp_target values (3, ''cte'') returning *) select * from w',
        'with w as (update t_sp_target set v = ''cte'' returning *) select * from w',
        'with w as (delete from t_sp_target returning *) select * from w',
        'explain analyze insert into t_sp_target values (4, ''explain'')',
        'select 1; insert into t_sp_target values (5, ''chained'')'
    ];
    s text;
    v_allowed text[] := '{}';
begin
    foreach s in array v_attempts loop
        begin
            perform aiq.sql_passthrough(s);
            v_allowed := v_allowed || s;      -- returned without raising
        exception when others then
            null;                              -- refused, which is the pass
        end;
    end loop;

    if array_length(v_allowed, 1) is not null then
        raise exception 'the passthrough executed a write: %', v_allowed;
    end if;
    if (select count(*) from t_sp_target) <> 1
       or (select v from t_sp_target where id = 1) <> 'before' then
        raise exception 'a refused statement still changed the table -- % row(s), id 1 is %',
            (select count(*) from t_sp_target), (select v from t_sp_target where id = 1);
    end if;
    raise notice 'query/07: nine write shapes refused, four of them past the keyword check';
end $$;

-- ...and the boundary is the transaction, not the regex. Asserted directly,
-- because "the regex happened to catch everything I thought of" and "writes
-- are impossible" are different claims and only the second one is the design.
do $$
begin
    if aiq.sql_passthrough('select current_setting(''transaction_read_only'')')
       -> 0 ->> 'current_setting' <> 'on' then
        raise exception
            'the statement did not run in a read-only transaction. Every write '
            'assertion above is then resting on a regex over the first keyword, '
            'which is a list of what somebody thought of';
    end if;
    raise notice 'query/07: the statement runs in a read-only transaction';
end $$;

-- ...and read-only cannot be switched off from inside the statement.
do $$
declare v_msg text;
begin
    begin
        perform aiq.sql_passthrough('select set_config(''transaction_read_only'', ''off'', true)');
        raise exception 'the caller turned the read-only boundary off from inside it';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg like 'the caller turned%' then raise; end if;
    end;
    raise notice 'query/07: the boundary cannot be lifted by the statement it bounds';
end $$;

-- ---------------------------------------------------------------------
-- 2. IT READS AS THE CALLER: RLS APPLIES, AND SO DO TABLE PRIVILEGES.
--
-- This is brief.md §3's correction, executed. SECURITY DEFINER here would
-- return every tenant's rows and every column of rbac.users to anyone allowed
-- to call the RPC -- and would do it silently, since the function's SQL is
-- whatever the caller wrote and there is no signature to notice.
-- ---------------------------------------------------------------------
do $$
declare v_secdef boolean;
begin
    select prosecdef into v_secdef from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'aiq' and p.proname = 'sql_passthrough';
    if v_secdef then
        raise exception
            'aiq.sql_passthrough is SECURITY DEFINER. It executes caller-supplied '
            'SQL, so that is an RLS bypass and a privilege-escalation primitive '
            '(brief.md §3)';
    end if;
    raise notice 'query/07: the passthrough is SECURITY INVOKER';
end $$;

rollback;

-- A separate transaction, because the assertions below need a real end-user
-- role and the fixture above needed an owner.
begin;
set local role authenticated;
set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000b"]}';

do $$
declare
    v_all int;
    v_seen int;
begin
    -- RLS: the passthrough must not see more nodes than the same role sees
    -- through an ordinary select.
    select count(*) into v_seen from aiq.nodes;
    v_all := (aiq.sql_passthrough('select count(*) as n from aiq.nodes') -> 0 ->> 'n')::int;
    if v_all <> v_seen then
        raise exception
            'the passthrough returned % nodes where the calling role can see % '
            '-- it is not being filtered by the caller''s policies', v_all, v_seen;
    end if;
    if v_all = (select count(*) from aiq.nodes_api) and v_all = 0 then
        raise exception 'the caller sees nothing at all, so this proves nothing';
    end if;

    -- ...and another tenant's node is not reachable by naming it directly,
    -- which is the query an attacker actually writes.
    if jsonb_array_length(aiq.sql_passthrough(
            'select id from aiq.nodes where org_id = ''a0000000-0000-0000-0000-00000000000a''')) <> 0 then
        raise exception 'the passthrough returned another tenant''s rows';
    end if;
    raise notice 'query/07: the passthrough is RLS-filtered as the caller (% nodes)', v_all;
end $$;

-- Table privileges are the other half, and they are what stops the interesting
-- reads: user-rbac withholds base-table access precisely because password_hash
-- and mfa_secret cannot be hidden by RLS (integration-rbac.sql §2).
do $$
declare
    v_reached text[] := '{}';
    s text;
    v_probes text[] := array[
        'select * from rbac.users',
        'select password_hash from rbac.users',
        'select * from pg_authid',
        'select pg_read_file(''/etc/passwd'')',
        'select current_setting(''request.jwt.claims'')'
    ];
begin
    foreach s in array v_probes loop
        begin
            perform aiq.sql_passthrough(s);
            v_reached := v_reached || s;
        exception when others then null;
        end;
    end loop;
    -- The last probe is expected to succeed: a caller reading back its own
    -- request claims learns nothing it did not present. It is in the list so
    -- that this assertion fails if the probes stop reaching the executor at
    -- all -- a passthrough that refuses everything would pass a
    -- refusals-only test while being broken.
    if v_reached <> array['select current_setting(''request.jwt.claims'')'] then
        raise exception 'the passthrough reached something it should not, or '
                        'nothing at all: %', v_reached;
    end if;
    raise notice 'query/07: secrets stay behind table privileges, and the hatch still opens';
end $$;

rollback;

-- ---------------------------------------------------------------------
-- 3. THE READ-ONLY SETTING IS TRANSACTION-SCOPED, SO IT OUTLIVES THE CALL.
--
-- set_config(..., true) is transaction-local -- deliberately, so it cannot
-- leak into a pooled connection's next transaction, which is the hazard
-- rbac.current_user_id() was hardened against. The consequence is that
-- everything AFTER the call, in the same transaction, is also read-only.
--
-- Under PostgREST that is invisible: one transaction per request. It is
-- documented and pinned here because the dialect is also reachable as a
-- workflow step, and a `p8ql` step that made the rest of its transaction
-- read-only would fail a later write step with "cannot execute INSERT in a
-- read-only transaction" -- an error naming neither the query nor the step
-- that caused it.
--
-- What makes that survivable today is asserted first: SQL mode does not
-- execute here. aiq.query returns the statement and tells the caller to run it
-- through this function, so a workflow step never reaches it.
-- ---------------------------------------------------------------------
begin;
set local role app_owner;
do $$
declare v jsonb;
begin
    v := aiq.query('select 1 from aiq.nodes');
    if v ->> 'mode' <> 'SQL' then
        raise exception 'a bare select is no longer recognised as SQL mode';
    end if;
    if v ? 'rows' then
        raise exception
            'the dispatch now EXECUTES SQL mode. It must not: aiq.query is '
            'reachable as a workflow step, and executing there would both run '
            'caller SQL inside the engine''s transaction and make the rest of '
            'that transaction read-only';
    end if;
    if v ->> 'statement' is null then
        raise exception 'SQL mode returns neither rows nor the statement';
    end if;
    raise notice 'query/07: SQL mode returns the statement rather than running it';
end $$;
rollback;

begin;
set local role app_owner;
create table t_sp_after (id int);
-- THE READ-ONLY SETTING NO LONGER OUTLIVES THE CALL, and this assertion is the
-- inverse of the one it replaces.
--
-- It used to read: "the caller could still write after calling the passthrough
-- -- that is not a security failure, but this file documents the opposite
-- behaviour". The behaviour was a leak with a note attached: transaction_read_only
-- is transaction-local, so one passthrough call turned the REST of the caller's
-- transaction read-only, from a line nowhere near the query.
--
-- It never bit over PostgREST, where every call is its own transaction. It bit
-- the moment something composed: workflow.p8ql now runs SQL mode through here
-- and then has to mark its own task done. So the read happens inside a
-- subtransaction that is deliberately unwound -- `transaction_read_only = off`
-- is refused inside a read-only transaction (25001), and a subtransaction abort
-- is the only way back.
do $$
begin
    perform aiq.sql_passthrough('select 1');
    begin
        insert into t_sp_after values (1);
    exception when read_only_sql_transaction then
        raise exception
            'the passthrough left the caller''s transaction read-only -- one call '
            'now makes every later write in that transaction fail, which is the '
            'leak the subtransaction unwind exists to close';
    end;
    if (select count(*) from t_sp_after) <> 1 then
        raise exception 'the write after the passthrough did not land';
    end if;
    raise notice 'query/07: the read-only setting is unwound with the passthrough''s own subtransaction';
end $$;
rollback;
