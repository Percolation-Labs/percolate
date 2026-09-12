-- ONE DERIVATION AND ONE DEFINITION (REM-58) -- the two questions this file
-- asks are the two that had more than one answer.
--
-- 1. A RUN'S SESSION ID. `workflow.run_meta` published `$session` as
--    percolate.uuidv5(id_namespace('session'), run_id) and
--    `workflow.run_session` computed md5(run_id || ':' || group)::uuid for the
--    same key. Two copies of one rule, and `fa59c8e` corrected one of them --
--    meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §1 exactly.
--    They also were not the same function of their inputs: md5 aside, the
--    empty group carried a trailing colon, so the strings differed too.
--
--    specs/identity/spec.md §3 is what md5 breaks: it produces a value whose
--    version nibble is 0, which is not a UUID and compares unequal to the id a
--    client recomputes from the same inputs. §4c of specs/identity/checks.sql
--    now asserts that on the rows themselves.
--
-- 2. WHICH VERSION A NAME MEANS. `deleted_at` says in its own comment that it
--    exists so nobody starts new runs against a version -- and start_workflow
--    resolved `order by version desc limit 1` without it while every plan view
--    filtered on it. A retired latest version was hidden from every list and
--    still ran.
--
--    Latent: nothing in core sets deleted_at, which is why §2 below sets it by
--    hand. That is the reason to fix it rather than a reason to leave it -- the
--    defect is unreachable today, so the fix cannot break a live caller.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

insert into workflow.definitions (name, spec) values
    ('t_rem58', '{"steps":[{"key":"only","kind":"work","queue":"t"}]}');

-- ---------------------------------------------------------------------
-- 1. The session id has one derivation, and it is a v5.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_meta uuid; v_fn uuid;
begin
    v_run := workflow.start_workflow('t_rem58', '{}'::jsonb);

    v_meta := (workflow.run_meta(v_run)->>'$session')::uuid;
    v_fn   := workflow.run_session(v_run);
    if v_meta is distinct from v_fn then
        raise exception
            'run_meta publishes $session as % and workflow.run_session() '
            'computes % for the same run -- two answers to one question', v_meta, v_fn;
    end if;

    -- THE VALUE, not just the agreement. Both could agree on a wrong one, and
    -- a version-0 uuid is what the identity spec bans.
    if uuid_extract_version(v_fn) <> 5 then
        raise exception
            'the session id is uuid version %, not 5 -- a client deriving it '
            'from the same inputs would not get this value', uuid_extract_version(v_fn);
    end if;

    -- Derived, so it converges: the same run yields the same id on every
    -- resolution, which is what makes it safe to omit a column for it.
    if workflow.run_session(v_run) <> workflow.run_session(v_run) then
        raise exception 'run_session is not stable for one run';
    end if;

    -- And a named group is still its own conversation, which is the whole
    -- reason the argument exists.
    if workflow.run_session(v_run, 'a') = workflow.run_session(v_run, 'b') then
        raise exception 'two groups of one run collide on a session id';
    end if;
    if workflow.run_session(v_run, 'a') = workflow.run_session(v_run) then
        raise exception 'a named group collides with the run''s own session';
    end if;

    raise notice 'workflow/18: one session derivation, version 5, stable, and groups stay apart';
end $$;

-- ---------------------------------------------------------------------
-- 2. A retired version is not startable, and not only unlisted.
-- ---------------------------------------------------------------------
do $$
declare v_started boolean := false;
begin
    -- Visible and startable to begin with, so §2 measures the change rather
    -- than a name that was never there.
    if (workflow.current_definition('t_rem58')).id is null then
        raise exception 'the fixture definition is not startable before it is retired';
    end if;

    update workflow.definitions set deleted_at = now() where name = 't_rem58';

    if (workflow.current_definition('t_rem58')).id is not null then
        raise exception
            'current_definition returned a version whose deleted_at is set -- '
            'the column says "do not start new runs against this version"';
    end if;

    begin
        perform workflow.start_workflow('t_rem58', '{}'::jsonb);
        v_started := true;
    exception when others then null;
    end;
    if v_started then
        raise exception
            'a retired definition still started a run: it is hidden from every '
            'plan view and the starter does not read the same rule (REM-58)';
    end if;

    -- The two gates one call along agree with the starter, which is what
    -- routing all three through current_definition buys.
    begin
        perform workflow.schedule_workflow('t-rem58-sched', 't_rem58', '* * * * *');
        raise exception 'a retired definition was accepted for scheduling';
    exception when others then null;
    end;

    raise notice 'workflow/18: a retired definition is refused by the starter and the scheduler, not only unlisted';
end $$;

rollback;
