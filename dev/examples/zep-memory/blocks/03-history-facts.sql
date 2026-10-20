-- psql, as p8: the worker writes what each memory says, from when it was said
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Ana Costa"}, {"k":"company","n":"Tagus Ceramics"},
            {"k":"place","n":"Lisbon"}, {"k":"port","n":"Rotterdam"}],
  "edges": [{"s":0,"t":1,"r":"works_at"}, {"s":0,"t":2,"r":"based_in"}, {"s":0,"t":3,"r":"ships_via"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-support-2026-01'),
                    'valid_from', '2026-01-14T09:30:00Z')) ->> 'edges_new' as january;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"A. Costa"}, {"k":"organization","n":"Tagus Ceramics"}, {"k":"mode","n":"rail"}],
  "edges": [{"s":0,"t":1,"r":"works_at"}, {"s":0,"t":2,"r":"prefers"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-email-2026-03'),
                    'valid_from', '2026-03-09T16:00:00Z')) ->> 'edges_new' as march;
-- an older reader, reader-v0, read the same email and got it wrong
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"A. Costa"}, {"k":"mode","n":"road"}],
  "edges": [{"s":0,"t":1,"r":"prefers"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-email-2026-03'),
                    'agent', 'reader-v0', 'run_id', 'mar-09', 'valid_from', '2026-03-09T16:00:00Z')) ->> 'edges_new' as misread;
