-- A QUERY IS RECORDED AS THE PERSON WHO RAN IT, AND ONLY THEY CAN READ IT.
--
-- content.record_query writes one `stored` row on the shipped query_log channel
-- per query a caller ran (world-model-ingestion/integration.sql, the query log).
-- What must hold:
--
--   1. an anonymous caller records nothing;
--   2. a signed-in caller's event becomes one private row they own, with the
--      event as its metadata, `stored` (so check_drift, which reports pending
--      rows, never will, and the graph projection, which takes ready ones,
--      leaves it out);
--   3. writing the same event again is the same row, not a second one;
--   4. another signed-in caller cannot read it;
--   5. an event with no id or no query, or over 64 KB, is refused.
--
-- No org and no permission fixture: the function asks only that the caller is
-- signed in, and that is what is varied here. A signed-in caller with no org
-- and no role is the weakest caller there is, so §2 passing for them is the
-- point rather than a gap.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

create temp table t_ql (a uuid, b uuid);
insert into t_ql values (gen_random_uuid(), gen_random_uuid());
grant select on t_ql to authenticated;

do $$
declare a uuid; b uuid;
begin
    select t.a, t.b into a, b from t_ql t;
    insert into rbac.users (id, email, status) values
        (a, 't-ql-a-' || left(a::text, 8) || '@example.test', 'active'),
        (b, 't-ql-b-' || left(b::text, 8) || '@example.test', 'active');
end $$;

-- 1. ANONYMOUS: refused with 42501, and nothing lands.
do $$
declare v_state text; v_msg text;
begin
    set local role authenticated;
    set local request.jwt.claims = '{}';
    begin
        perform content.record_query('{"id": "t-ql-anon", "query": "TEXT \"x\""}'::jsonb);
        raise exception 'AN ANONYMOUS CALLER RECORDED A QUERY';
    exception when others then
        v_state := sqlstate; v_msg := sqlerrm;
        if v_msg like 'AN ANONYMOUS%' then raise; end if;
    end;
    if v_state is distinct from '42501' or v_msg not like 'Only a signed-in caller%' then
        raise exception 'the anonymous refusal was not the designed one: % %', v_state, v_msg;
    end if;
    reset role;
    if exists (select 1 from content.resources where external_id like '%:t-ql-anon') then
        raise exception 'the refusal still wrote the row';
    end if;
    raise notice 'content/11: an anonymous caller records nothing';
end $$;

-- 2 and 3. A SIGNED-IN CALLER: one private stored row they own, the same row twice.
do $$
declare a uuid; v1 uuid; v2 uuid; r record;
begin
    select t.a into a from t_ql t;
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', json_build_object('sub', a)::text);
    v1 := content.record_query(jsonb_build_object(
        'id', 't-ql-1', 'query', 'TEXT "Arthur" FROM dracula',
        'question', 'Which entries never mention Arthur?',
        'raised', jsonb_build_array(jsonb_build_object('code', 'NEGATION'))));
    v2 := content.record_query(jsonb_build_object('id', 't-ql-1', 'query', 'a retry'));
    if v1 is null or v1 is distinct from v2 then
        raise exception 'a repeated event made a second row or none: % %', v1, v2;
    end if;
    -- the caller reads their own row through RLS, as any read path would
    select * into r from content.resources where id = v1;
    if not found then
        raise exception 'the caller cannot read the query they recorded';
    end if;
    reset role;
    if r.status <> 'stored' or r.visibility <> 'private' or r.owner_id is distinct from a
       or r.metadata->>'question' is distinct from 'Which entries never mention Arthur?'
       or r.metadata->'raised'->0->>'code' is distinct from 'NEGATION'
       or r.title is distinct from 'Which entries never mention Arthur?' then
        raise exception 'the stored row is not the private stored record of the event: %', row_to_json(r);
    end if;
    -- the first write stands: a retry with other content does not overwrite it
    if r.metadata->>'query' is distinct from 'TEXT "Arthur" FROM dracula' then
        raise exception 'a retry overwrote the first record';
    end if;
    raise notice 'content/11: a signed-in caller''s query is one private stored row, written once';
end $$;

-- 4. ANOTHER CALLER cannot read it.
do $$
declare b uuid; n int;
begin
    select t.b into b from t_ql t;
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', json_build_object('sub', b)::text);
    select count(*) into n from content.resources where external_id like '%:t-ql-1';
    reset role;
    if n <> 0 then
        raise exception 'another signed-in caller can read % query event(s) that are not theirs', n;
    end if;
    raise notice 'content/11: another caller cannot read someone''s queries';
end $$;

-- 5. MALFORMED AND OVERSIZED events are refused.
do $$
declare a uuid;
begin
    select t.a into a from t_ql t;
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', json_build_object('sub', a)::text);
    begin
        perform content.record_query('{"query": "no id"}'::jsonb);
        raise exception 'AN EVENT WITH NO ID WAS RECORDED';
    exception when invalid_parameter_value then null; end;
    begin
        perform content.record_query('{"id": "t-ql-noq"}'::jsonb);
        raise exception 'AN EVENT WITH NO QUERY WAS RECORDED';
    exception when invalid_parameter_value then null; end;
    begin
        perform content.record_query(jsonb_build_object('id', 't-ql-big', 'query', 'x',
                                                        'pad', repeat('y', 70000)));
        raise exception 'AN EVENT OVER 64 KB WAS RECORDED';
    exception when check_violation then null; end;
    reset role;
    raise notice 'content/11: malformed and oversized events are refused';
end $$;

rollback;
