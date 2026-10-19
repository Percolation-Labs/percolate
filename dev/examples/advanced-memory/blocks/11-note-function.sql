create or replace function pg_temp.note(p_title text, p_claim text) returns uuid language sql as $$
  select (research.submit_package(jsonb_build_object(
    'schema_version', '0.1', 'title', p_title, 'visibility', 'listed', 'edges', '[]'::jsonb,
    'claims',  jsonb_build_array(jsonb_build_object('id', 'C1', 'kind', 'Inference', 'text', p_claim,
                                                    'source_ids', '["S1"]'::jsonb)),
    'sources', jsonb_build_array(jsonb_build_object('id', 'S1', 'title', p_title, 'origin', p_title,
                                                    'url', 'https://example.com/' || md5(p_title))))) ->> 'revision_id')::uuid
$$;
