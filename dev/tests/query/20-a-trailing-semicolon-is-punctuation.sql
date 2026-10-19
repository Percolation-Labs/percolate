-- A single read query that ends in a semicolon runs (REM-1019).
--
-- aiq.sql_passthrough wraps the caller's statement in a subquery, where a
-- trailing `;` is a syntax error, so `select 1;` was refused as if it were a
-- second statement. It now strips one trailing semicolon and whitespace:
--   1. `select 1;` runs;
--   2. `select 1 ;` followed by a newline runs;
--   3. `select 1; select 2` is still refused, and the hint says two statements.
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

do $$
declare
    v jsonb;
    v_hint text;
begin
    v := aiq.sql_passthrough('select 1 as n;');
    if v <> '[{"n": 1}]'::jsonb then
        raise exception 'query/20: `select 1 as n;` returned %, expected [{"n": 1}]', v;
    end if;

    v := aiq.sql_passthrough(e'select 1 as n ;\n  ');
    if v <> '[{"n": 1}]'::jsonb then
        raise exception 'query/20: `select 1 as n ;` plus whitespace returned %', v;
    end if;

    begin
        perform aiq.sql_passthrough('select 1; select 2');
        raise exception 'query/20: `select 1; select 2` ran; a second statement must be refused';
    exception when syntax_error then
        get stacked diagnostics v_hint = pg_exception_hint;
        if v_hint not like '%two statements%' then
            raise exception 'query/20: the refusal''s hint was %, expected it to name two statements', v_hint;
        end if;
    end;
end $$;

\echo 'query/20: a trailing semicolon runs, and a second statement is refused naming it'
rollback;
