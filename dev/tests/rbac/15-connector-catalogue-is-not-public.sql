-- loads: world-model-ingestion/connectors.sql
--
-- THE CONNECTOR CATALOGUE IS NOT READABLE BY ANYONE WHO HAS NOT SIGNED IN --
-- and, it turned out, not by most people who have (REM-82).
--
-- content.due_connectors is SECURITY DEFINER, `select *` over whole rows, with
-- no org or owner predicate, and it was granted to `authenticated, web_anon`.
-- That was the reported defect. The sibling sweep found four more grants in the
-- same block, one of them worse: `grant select, insert, update, delete on
-- content.connectors to authenticated`, on a table that takes neither
-- rbac.add_scope_columns() nor rbac.add_scope_policy() -- so no RLS, no owner
-- column, and any signed-in user could delete the whole catalogue.
--
-- WHY THIS FILE LOADS ITS OWN SUBJECT. connectors.sql is in build-sql.py's
-- NOT_SHIPPED: `create extension percolate` does not contain it, so
-- content.connectors exists in no database this suite runs against. An
-- assertion whose subject is absent is not a measurement -- it is the thing
-- dev/assertion-audit.py exists to refuse -- so this file asks run.sh for the
-- real file (`-- loads:` above), installs it inside a transaction, asks the
-- catalogue, and rolls back.
--
-- That is NOT a grep over the file's text for `web_anon`, and the choice is
-- the point of the file. REM-73
-- has just finished removing two assertions of exactly that shape from
-- content/01, where they passed on comments saying the greped-for name was
-- unused. Postgres parses the grants; this file reads has_table_privilege and
-- has_function_privilege. Same question, asked exactly.
--
-- The grants are live wherever the file has been hand-loaded -- dev/currency.sh
-- once found content.connectors* ORPHAN on a running stack, and sources.md §17
-- registers 304 sources through it against a live deployment -- and latent
-- everywhere else until the file enters ORDER. This file is what makes the day
-- it enters ORDER a safe day.
--
-- NOT DECLARED IN dev/tests/rbac/14. That file's direction (b) holds every
-- declared function to "still exists and is still reachable" in the live
-- catalogue; a row for content.due_connectors would name a function that is not
-- installed and would fail it. When connectors.sql moves into ORDER the rows
-- belong there, and rbac/14's own (a) direction will demand them without
-- anybody remembering to.

\set ON_ERROR_STOP on

begin;

set local role app_owner;
\i /tmp/connectors.sql

-- ---------------------------------------------------------------------
-- 0. The subject exists and is the real one.
--
-- First, because every assertion below is about objects this transaction just
-- created: if the load brought in nothing, all of them would be asking about
-- nothing and passing.
-- ---------------------------------------------------------------------
do $$
declare v_missing text;
begin
    select string_agg(want, ', ' order by want) into v_missing
      from (values ('content.connectors'), ('content.v_connectors'),
                   ('content.v_connectors_attention'),
                   ('content.v_required_credentials'), ('content.v_build_order')) t(want)
     where to_regclass(want) is null;
    if v_missing is not null then
        raise exception
            '-- loads: did not bring in the connector surface -- missing %. Every '
            'assertion in this file would pass on an absent subject', v_missing;
    end if;
    if to_regprocedure('content.due_connectors(int)') is null
       or to_regprocedure('content.report_connector_run(text,text,int,text,text,int,jsonb)') is null then
        raise exception 'the connector RPCs are not present after the load';
    end if;
    raise notice 'rbac/15: the not-shipped connector surface is loaded, in a transaction that will roll back';
end $$;

-- ---------------------------------------------------------------------
-- 1. web_anon -- the anonymous role -- reaches none of it.
--
-- Asked of every object the file creates rather than of the one that was
-- reported, which is the whole lesson of the postmortem this came from: the
-- reported grant was the fourth of five, and the raw table carried `headers`
-- and the full `auth` object that the view does not.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(obj || ' (' || priv || ')', ', ' order by obj, priv) into v_bad
      from (values ('content.connectors'), ('content.v_connectors'),
                   ('content.v_connectors_attention'),
                   ('content.v_required_credentials'), ('content.v_build_order')) o(obj),
           (values ('select'), ('insert'), ('update'), ('delete')) p(priv)
     where has_table_privilege('web_anon', o.obj, p.priv);
    if v_bad is not null then
        raise exception
            'web_anon can reach the connector catalogue: % -- the source list, '
            'its urls, headers, credential names and commercial scoring are '
            'readable by anybody who can reach PostgREST', v_bad;
    end if;

    if has_function_privilege('web_anon', 'content.due_connectors(int)', 'execute') then
        raise exception
            'web_anon can execute content.due_connectors -- a SECURITY DEFINER '
            'select * over whole rows with no org or owner predicate';
    end if;
    if has_function_privilege('web_anon',
        'content.report_connector_run(text,text,int,text,text,int,jsonb)', 'execute') then
        raise exception 'web_anon can execute content.report_connector_run, which WRITES';
    end if;

    raise notice 'rbac/15: an anonymous caller reaches no connector row, view or RPC';
end $$;

-- ---------------------------------------------------------------------
-- 2. An ordinary signed-in caller reaches none of it either.
--
-- `authenticated` is every person who has logged in, and the catalogue has no
-- tenant column, so there is no row question that would let one of them in.
-- The DELETE arm is asserted by name: it was granted, and content.connectors
-- has no RLS to have stopped it.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(obj || ' (' || priv || ')', ', ' order by obj, priv) into v_bad
      from (values ('content.connectors'), ('content.v_connectors'),
                   ('content.v_connectors_attention'),
                   ('content.v_required_credentials'), ('content.v_build_order')) o(obj),
           (values ('select'), ('insert'), ('update'), ('delete')) p(priv)
     where has_table_privilege('authenticated', o.obj, p.priv);
    if v_bad is not null then
        raise exception
            'a signed-in caller can reach the connector catalogue: % -- and the '
            'table takes no add_scope_policy, so there is no RLS behind the '
            'grant', v_bad;
    end if;

    if has_function_privilege('authenticated', 'content.due_connectors(int)', 'execute') then
        raise exception 'a signed-in caller can enumerate the catalogue through due_connectors';
    end if;
    if has_function_privilege('authenticated',
        'content.report_connector_run(text,text,int,text,text,int,jsonb)', 'execute') then
        raise exception
            'a signed-in caller can rewrite any connector''s health and status '
            'by naming its id, through report_connector_run';
    end if;

    -- and api_viewer, which holds authenticated's grants by membership and is
    -- the role the *_api views are handed to -- so a grant to `authenticated`
    -- that this file missed would still be reachable through it
    if has_table_privilege('api_viewer', 'content.connectors', 'select') then
        raise exception 'api_viewer can read the connector catalogue';
    end if;

    raise notice 'rbac/15: an ordinary signed-in caller reaches no connector row, view or RPC';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE WORKER PATH STILL WORKS, which is the half that keeps this a check
--    rather than an outage.
--
-- sources.md §17.3 says these RPCs are SECURITY DEFINER "so a worker with no
-- table grant can call it". That sentence is the reason for the definer AND the
-- statement of who should hold it, and §2 above is only correct if this passes:
-- a revoke that also stopped the runner would have moved the problem, not
-- fixed it.
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
    if not has_function_privilege('worker', 'content.due_connectors(int)', 'execute') then
        raise exception
            'the worker cannot call due_connectors -- the runner has no way to '
            'claim work, which is what the definer exists for';
    end if;
    if not has_function_privilege('worker',
        'content.report_connector_run(text,text,int,text,text,int,jsonb)', 'execute') then
        raise exception 'the worker cannot report a run outcome';
    end if;
    if not has_table_privilege('worker', 'content.connectors', 'select') then
        raise exception 'the worker cannot read the catalogue it polls';
    end if;

    -- and it RUNS, not merely holds a grant: a privilege that raises when
    -- exercised is not a working path. Executed as the worker login, which is
    -- where the definer's own operator arm is decided.
    set local role worker;
    select count(*) into v_n from content.due_connectors(5);
    if v_n is distinct from 0 then
        raise exception 'the freshly created catalogue is not empty: % row(s)', v_n;
    end if;
    reset role;

    raise notice 'rbac/15: the worker still claims work and reports outcomes -- the revoke did not move the problem';
end $$;

-- ---------------------------------------------------------------------
-- 4. classify_health is NOT in the list above, and that is a decision.
--
-- It is immutable, takes three scalars, reads no table and returns a word, so
-- there is no row in it to scope. Asserted rather than left to a comment,
-- because a later reader tightening §1 and §2 by reflex would otherwise sweep
-- it up and break the runner for no gain.
-- ---------------------------------------------------------------------
do $$
begin
    if not has_function_privilege('web_anon', 'content.classify_health(int,text,int)', 'execute') then
        raise exception
            'classify_health has been revoked from web_anon -- it reads no rows, '
            'so this is a cost with nothing bought; if it was meant, this '
            'assertion is the place to say why';
    end if;
    raise notice 'rbac/15: classify_health stays broad -- pure arithmetic over three scalars, no row to scope';
end $$;

rollback;
