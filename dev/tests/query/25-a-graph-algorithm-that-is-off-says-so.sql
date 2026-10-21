-- A GRAPH ALGORITHM THAT IS OFF SAYS SO, AND NAMES ITS SWITCH (REM-1087).
--
-- The graph algorithms ship switched off per role: the switch is the grant on
-- the compiled p8_graph_* functions, which aiq.enable_graph_algorithms(role)
-- gives. Through p8ql a caller was told so. A direct call to a wrapper met
-- Postgres's bare `permission denied for function related`, which names
-- neither the switch nor that there is one. Now:
--
--   1. every wrapper, called directly by a role the switch is off for, refuses
--      with insufficient_privilege, says the algorithms are off for that role,
--      and its hint is the exact call that turns them on;
--   2. p8ql still answers in its own words;
--   3. the boundary report still says the crossing is not callable, though the
--      wrapper itself now is;
--   4. with the switch on, the same call is past the gate.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
select aiq.enable_graph_algorithms('authenticated', false) \g /dev/null
insert into rbac.users (id, email, status) values ('00000000-0000-4000-8000-000000108701', 'off@example.test', 'active');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000108701"}', true) \g /dev/null
set local role authenticated;

do $$
declare
    call  text;
    msg   text;
    hint  text;
    state text;
begin
    foreach call in array array[
        'select aiq.related(array[''acme''])',
        'select aiq.graph_paths(''acme'', ''beta'')',
        'select aiq.graph_connect(array[''acme'', ''beta''])',
        'select aiq.graph_dense(''acme'')',
        'select aiq.graph_trust(array[''acme''])',
        'select aiq.graph_frontier(''acme'')',
        'select aiq.graph_reach_build()',
        'select count(*) from aiq.graph_components()',
        'select count(*) from aiq.graph_induced(array[]::uuid[])',
        'select aiq.graph_snapshot()',
        'select aiq.graph_snapshot_drop()'] loop
        begin
            execute call;
            raise exception 'a switched-off graph algorithm ran: %', call;
        exception when insufficient_privilege then
            get stacked diagnostics msg = message_text, hint = pg_exception_hint;
            if msg is distinct from 'the graph algorithms ship switched off, and they are off for role authenticated' then
                raise exception '%: the refusal does not say the switch is off: %', call, msg;
            end if;
            if hint not like '%select aiq.enable_graph_algorithms(''authenticated'')%' then
                raise exception '%: the refusal does not name the switch: %', call, hint;
            end if;
        end;
    end loop;

    -- 2. p8ql words it for its own caller, as it did.
    begin
        perform aiq.query('RELEVANCE "acme"');
        raise exception 'RELEVANCE ran with the switch off';
    exception when others then
        get stacked diagnostics msg = message_text;
        if msg not like '%ship switched off%aiq.enable_graph_algorithms(''authenticated'')%' then
            raise exception 'p8ql RELEVANCE no longer names the switch: %', msg;
        end if;
    end;

    -- 3. The wrapper is callable now, and the crossing still is not.
    if (aiq.extension_boundary()->>'ok')::boolean then
        raise exception 'the boundary report says ok with the switch off';
    end if;
    if not aiq.extension_boundary()->'unreachable' ? 'aiq.related' then
        raise exception 'the boundary report no longer lists aiq.related as unreachable: %',
            aiq.extension_boundary()->'unreachable';
    end if;
end $$;

-- 4. Switched on, by the owner: the same call is past the gate.
reset role;
select aiq.enable_graph_algorithms('authenticated') \g /dev/null
set local role authenticated;
do $$
begin
    perform aiq.graph_snapshot();
exception when insufficient_privilege then
    raise exception 'with the switch on, the call is still refused: %', sqlerrm;
end $$;

rollback;
