-- A WALK READS ITS PARAMETERS FROM ONE TABLE (Sirsh, M-20261027-213302-a399).
--
-- Every number and wording the walk, its decider and its explanations read is a row of aiq.parameters, which also
-- says what it controls, where it is read and why. What is held:
--   1. every row explains itself: controls, read_by and why are written, and each part's name is its prefix;
--   2. a walk's settings are the table's walk rows, so changing a row changes the walk, and a run's own settings
--      still win over the table;
--   3. the decider's wording is the table's, so a verdict is kept under the wording the table holds;
--   4. a value tuned on a deployment survives the spec's seeding, and a value the spec still owns is refreshed.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

do $$
declare
    v jsonb;
begin
    -- 1. Each row explains itself.
    if exists (select 1 from aiq.parameters where btrim(controls) = '' or btrim(read_by) = '' or btrim(why) = '') then
        raise exception 'a parameter does not say what it controls, where it is read or why';
    end if;
    if (select count(*) from aiq.parameters where part = 'walk') < 10 then
        raise exception 'the walk''s parameters are not in the table: %', aiq.parameters_of('walk');
    end if;

    -- 2. The walk reads the table, and a run's settings win.
    update aiq.parameters set value = '7', set_by = 'query41', why = 'query/41' where name = 'walk.span';
    if (aiq.walk_settings('{}')->>'span')::int <> 7 then
        raise exception 'walk_settings did not read walk.span from the table: %', aiq.walk_settings('{}');
    end if;
    if (aiq.walk_settings('{"settings": {"span": 3}}')->>'span')::int <> 3 then
        raise exception 'a run''s own span did not win over the table';
    end if;

    -- 3. The decider's wording is the table's.
    update aiq.parameters set value = to_jsonb(text 'query41 wording') where name = 'decider.task';
    if aiq.walk_task() <> 'query41 wording' then
        raise exception 'walk_task did not read decider.task from the table: %', aiq.walk_task();
    end if;

    -- 4. Seeding again (as an upgrade does) keeps the tuned span and restores the wording the spec still owns.
    insert into aiq.parameters as p (name, part, value, controls, read_by, why)
    values ('walk.span', 'walk', '2', 'x', 'x', 'x'), ('decider.task', 'decider', to_jsonb(text 'spec wording'), 'x', 'x', 'x')
    on conflict (name) do update
       set value = excluded.value, controls = excluded.controls, read_by = excluded.read_by, why = excluded.why
     where p.set_by = 'spec';
    if (aiq.walk_settings('{}')->>'span')::int <> 7 then
        raise exception 'seeding overwrote a value a deployment tuned';
    end if;
    if aiq.walk_task() <> 'spec wording' then
        raise exception 'seeding did not refresh a value the spec still owns';
    end if;
    raise notice 'query/41: a walk reads its parameters from one table that explains them';
end $$;

rollback;
