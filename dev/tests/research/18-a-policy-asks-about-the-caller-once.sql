-- research.works' access policy asks about the caller once per query, not once per row (REM-528).
-- rbac.current_user_id() and rbac.may() depend only on the transaction's claims, so a subselect lets Postgres
-- evaluate them as an InitPlan. This reads the plan of a plain works query, as anonymous and as a person, and
-- fails if either call appears in a per-row filter. What each caller may see is unchanged: the policy is the same
-- predicate, and the other research tests prove the rows.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-00000000c528', 'rp-once-alice@example.test', 'active');

create function pg_temp.works_plan() returns text language plpgsql as $$
declare
    plan text := '';
    line text;
begin
    for line in execute 'explain (costs off) select 1 from research.works' loop
        plan := plan || line || E'\n';
    end loop;
    return plan;
end $$;

set local request.jwt.claims = '{}';
set local role authenticated;
do $$
declare plan text := pg_temp.works_plan();
begin
    assert plan !~ 'Filter:[^\n]*rbac\.may\(', 'anonymous: rbac.may runs per row' || E'\n' || plan;
    assert plan ~ 'InitPlan', 'anonymous: the caller checks are InitPlans' || E'\n' || plan;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000c528"}';
set local role authenticated;
do $$
declare plan text := pg_temp.works_plan();
begin
    assert plan !~ 'Filter:[^\n]*rbac\.may\(', 'a person: rbac.may runs per row' || E'\n' || plan;
end $$;
reset role;

rollback;
