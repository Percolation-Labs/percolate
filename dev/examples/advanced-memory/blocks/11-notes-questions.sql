create or replace function pg_temp.note(p_title text, p_claim text) returns uuid language sql as $$
  select (research.submit_package(jsonb_build_object(
    'schema_version', '0.1', 'title', p_title, 'visibility', 'listed', 'edges', '[]'::jsonb,
    'claims',  jsonb_build_array(jsonb_build_object('id', 'C1', 'kind', 'Inference', 'text', p_claim,
                                                    'source_ids', '["S1"]'::jsonb)),
    'sources', jsonb_build_array(jsonb_build_object('id', 'S1', 'title', p_title, 'origin', p_title,
                                                    'url', 'https://example.com/' || md5(p_title))))) ->> 'revision_id')::uuid
$$;

select claims.pose_question('Should the harbour analytics move off Postgres?') as q_postgres \gset
select claims.pose_question('Should an agent''s memory record when each fact became true?') as q_memory \gset
select claims.pose_question('Is a method validated at one clinic valid at another hospital?') as q_clinic \gset

select claims.propose_answer(pg_temp.note('Berth log benchmark, March',
         'DuckDB scanned a year of berth logs in 4 seconds where Postgres took 41.'), 'C1', :'q_postgres', 'yes');
select claims.propose_answer(pg_temp.note('Ops review, April',
         'Postgres already holds the berth logs and every permission on them; a second store doubles both.'), 'C1', :'q_postgres', 'no');
select claims.propose_answer(pg_temp.note('Agent memory notes',
         'An assistant that dates a fact by when it was stored answers questions about the past wrongly.'), 'C1', :'q_memory', 'yes');
select claims.propose_answer(pg_temp.note('Clinical transfer study',
         'A triage method validated in one hospital lost a third of its accuracy in two others.'), 'C1', :'q_clinic', 'no');
