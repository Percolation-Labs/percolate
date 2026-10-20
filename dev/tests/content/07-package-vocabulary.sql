-- A package's declared relations are relations its own derivations can write.
--
-- apply_package put a manifest's `relations` into aiq.relation_types and then
-- refreshed the vocabulary without them, so aiq.upsert_graph -- the path every
-- knit and dream stage writes through -- dropped each one as an unknown
-- relation and said so only in its receipt. Found by our end-to-end tour, whose
-- package install test asked the vocabulary rather than the catalogue.
\set ON_ERROR_STOP on
begin;
set local role app_owner;
create schema t_pkgvoc;
-- No org_id: a nullable one is what percolate.check_package_schema refuses
-- (content/08), and nothing here is about tenancy.
create table t_pkgvoc.widgets (id uuid not null default gen_random_uuid() unique, key text primary key);
insert into t_pkgvoc.widgets (key) values ('w-1'), ('w-2');
set local request.jwt.claims = '{}';
do $$ declare r jsonb; g jsonb; begin
    r := percolate.apply_package($m${
      "name": "t-pkg-vocabulary", "version": "0.1.0",
      "entity_types": [{"name": "t_widget", "table": "t_pkgvoc.widgets", "key": "n.key"}],
      "relations": [["t_widget", "t_feeds", "t_widget", "t_fed_by"]]
    }$m$::jsonb);
    if not exists (select 1 from aiq.graph_vocabulary where relation = 't_feeds') then
        raise exception 'a package relation is not in the machine vocabulary';
    end if;
    -- the behaviour that matters: an extraction in the package's own relation lands
    g := aiq.upsert_graph('{"nodes":[{"k":"t_widget","n":"w-1"},{"k":"t_widget","n":"w-2"}],
                            "edges":[{"s":0,"t":1,"r":"t_feeds"}]}'::jsonb, '{"agent":"t"}'::jsonb);
    if coalesce((g->>'edges_new')::int, 0) <> 1 then
        raise exception 'the package relation did not land: %', g;
    end if;
    -- and the declared inverse flips a backwards extraction instead of dropping it
    g := aiq.upsert_graph('{"nodes":[{"k":"t_widget","n":"w-2"},{"k":"t_widget","n":"w-1"}],
                            "edges":[{"s":0,"t":1,"r":"t_fed_by"}]}'::jsonb, '{"agent":"t2"}'::jsonb);
    if (g->>'edges_flipped_to_inverse')::int is distinct from 1
       or jsonb_array_length(g->'edges_dropped_unknown_relation') <> 0 then
        raise exception 'the inverse label was not honoured: %', g;
    end if;
    raise notice 'content/07: package relations are machine-writable, inverses included';
end $$;
rollback;
