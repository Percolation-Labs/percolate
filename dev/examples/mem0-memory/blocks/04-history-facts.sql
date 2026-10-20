-- psql, as p8: the worker writes what each memory says, from when it was said; June closes January's home
select aiq.upsert_graph(
 '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Leeds"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-01'),
                    'valid_from', '2026-01-05T09:00:00Z')) ->> 'edges_new' as january;
select aiq.close_edge(jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-01'),
                                         'relation', 'lives_in'),
 '2026-06-01T10:00:00Z',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-06'))) as closed;
select aiq.upsert_graph(
 '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Lisbon"},{"k":"company","n":"Harbour Health"}],
   "edges":[{"s":0,"t":1,"r":"lives_in"},{"s":0,"t":2,"r":"works_at"}]}',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-06'),
                    'valid_from', '2026-06-01T10:00:00Z')) ->> 'edges_new' as june;
