select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Harbour Rewrite"}, {"k":"tool","n":"Postgres"},
            {"k":"organization","n":"Harbour Health"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}, {"s":0,"t":2,"r":"prefers"}, {"s":0,"t":3,"r":"member_of"}]}$g$,
 '{"agent":"knit","run_id":"jan-12","valid_from":"2026-01-12T10:00:00Z"}') ->> 'edges_new' as jan_12;

select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Harbour Rewrite"},
            {"k":"person","n":"P. Raman"}, {"k":"tool","n":"DuckDB"}, {"k":"company","n":"Harbour Health"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}, {"s":2,"t":3,"r":"prefers"}, {"s":0,"t":4,"r":"member_of"}]}$g$,
 '{"agent":"knit","run_id":"mar-03","valid_from":"2026-03-03T15:00:00Z"}') ->> 'edges_merged' as mar_03_merged;

select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"tool","n":"MySQL"}],
  "edges": [{"s":0,"t":1,"r":"prefers"}]}$g$,
 '{"agent":"knit-bad","run_id":"apr-20","valid_from":"2026-04-20T09:00:00Z"}') ->> 'edges_new' as apr_20;

select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Tide Dashboard"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}]}$g$,
 '{"agent":"knit","run_id":"jun-02","valid_from":"2026-06-02T08:30:00Z"}') ->> 'edges_new' as jun_02;
