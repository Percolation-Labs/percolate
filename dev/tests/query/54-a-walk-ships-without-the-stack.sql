-- A WALK SHIPS WITHOUT THE QUESTION STACK (REM-1244).
--
-- The two-arm pilot decided the default by the rule registered before it ran: the stack's 95% interval against the
-- plain walk at 100 reads lay wholly below +5 points (-1.1 [-3.1, +0.2]), so walk.stack is false by default and
-- the board is an opt-in. This pins the shipped default on a fresh install. That an upgraded database carries the
-- same value is dev/upgrade-converges.sh's 'par' section, which compares every spec-set default between a fresh
-- install and one upgraded from the last release.

\set ON_ERROR_STOP on

begin;

do $$
begin
    if aiq.parameter('walk.stack') is distinct from 'false'::jsonb then
        raise exception 'walk.stack defaults to %, where the pilot decided false (REM-1244)', aiq.parameter('walk.stack');
    end if;
    if (aiq.parameters_of('walk')->>'stack') is distinct from 'false' then
        raise exception 'the walk part reads stack as %', aiq.parameters_of('walk')->>'stack';
    end if;
    if (select set_by from aiq.parameters where name = 'walk.stack' and valid_to is null) is distinct from 'spec' then
        raise exception 'walk.stack is not the spec''s row';
    end if;
    raise notice 'query/54: walk.stack defaults to false';
end $$;

rollback;
