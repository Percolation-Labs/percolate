-- 5. A file becomes answerable.
--
-- register_upload records that bytes exist somewhere; record_chunks records
-- what they say. Neither needs the bytes in Postgres -- the file lives in
-- object storage and the row carries the bucket and key.
set local role authenticated;
set local request.jwt.claims = '{"orgs":["d0000000-0000-0000-0000-00000000000a"]}';

select content.register_upload(
    p_channel      => 'harbour-reports',
    p_checksum     => 'sha256:6f1a9c',
    p_bucket       => 'harbour',
    p_object_key   => 'psc/2026/gothenburg-9214578.pdf',
    p_size_bytes   => 48213,
    p_content_type => 'application/pdf',
    p_title        => 'Gothenburg PSC report',
    p_org_id       => 'd0000000-0000-0000-0000-00000000000a',
    p_external_id  => 'psc-2026-018'
) as resource_id \gset

\echo '-- what the parser produced, with spans back into the source:'
select content.record_chunks(:'resource_id'::uuid, $j$[
  {"ordinal":0,"content":"Gothenburg PSC inspection found the auxiliary boiler within tolerance.","start_char":0,"end_char":69},
  {"ordinal":1,"content":"No deficiencies were recorded against Aurora Kestrel on this call.","start_char":70,"end_char":135}
]$j$::jsonb) as chunks_recorded;

\echo '-- queryable immediately, with no reindex step anywhere:'
select round((r->>'score')::numeric,4) as score, left(r->>'content',52) as content
from jsonb_array_elements(aiq.query('TEXT "Gothenburg" FROM chunks LIMIT 3')->'rows') r;

-- The two dedup keys, which are not the same key and do not do the same job.
\echo '-- same external_id -> the SAME resource, updated:'
select content.register_upload('harbour-reports','sha256:6f1a9c','harbour',
    'psc/2026/gothenburg-9214578.pdf',48213,'application/pdf','Gothenburg PSC report',
    null,'d0000000-0000-0000-0000-00000000000a','{}'::jsonb,'psc-2026-018')
    = :'resource_id'::uuid as same_resource;

\echo '-- same bytes, NO external_id -> a second resource over the same file.'
\echo '-- The checksum dedups the bytes; only external_id dedups the'
\echo '-- registration, so an upload retried without one ingests twice.'
select content.register_upload('harbour-reports','sha256:6f1a9c','harbour',
    'psc/2026/gothenburg-9214578.pdf',48213,'application/pdf','Gothenburg PSC report',
    null,'d0000000-0000-0000-0000-00000000000a') as second_resource \gset
select (:'second_resource'::uuid = :'resource_id'::uuid) as same_resource,
       (select file_id from content.resources where id = :'second_resource'::uuid)
     = (select file_id from content.resources where id = :'resource_id'::uuid) as same_file;
