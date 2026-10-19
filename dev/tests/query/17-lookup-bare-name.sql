-- LOOKUP BY A BARE NAME FINDS A SOFT NODE, AND SAYS UNDER WHICH KIND (REM-995).
--
-- A soft node's only canonical key is `<kind>/<name>`, so `LOOKUP "Harbour
-- Rewrite"` returned nothing and only `LOOKUP "project/harbour rewrite"` found
-- it: a reader had to know a kind prefix nothing had shown them (feedback
-- 2e60551b). aiq.lookup now tries the name after the prefix once every typed
-- tier has missed.
--
-- WHAT WOULD MAKE IT FAIL. Remove the soft step from aiq.lookup and §1 raises.
-- Move it ahead of the canonical step and §2 raises, because the soft node
-- would answer for a typed node of the same name.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

create table demo_t995_project (
    id     uuid primary key default gen_random_uuid(),
    name   text not null,
    listed boolean not null default true,
    org_id uuid
);
select aiq.register_entity_table(
    'ttype_t995_project', 'public.demo_t995_project', 'n.name', 'n.name', 'n.org_id', 'n.listed') \g /dev/null
select aiq.register_graph_vocabulary('[{"relation":"leads"}]') \g /dev/null

set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"person","n":"Ada Lane"},{"k":"project","n":"Harbour Rewrite"},
               {"k":"project","n":"Lantern"},{"k":"place","n":"Lantern"}],
      "edges":[{"s":0,"t":1,"r":"leads"},{"s":0,"t":2,"r":"leads"},{"s":0,"t":3,"r":"leads"}]}',
    '{"agent":"t995"}') \g /dev/null
reset role;
set local role app_owner;

-- 1. A bare name finds the soft node, and the key it returns names the kind.
do $$
declare r jsonb := aiq.query('LOOKUP "Harbour Rewrite"');
begin
    if jsonb_array_length(r->'rows') is distinct from 1 then
        raise exception 'LOOKUP "Harbour Rewrite" returned % rows; a soft node should answer its bare name',
            jsonb_array_length(r->'rows');
    end if;
    if r->'rows'->0->>'key' is distinct from 'project/harbour rewrite'
       or r->'rows'->0->>'match_kind' is distinct from 'soft' then
        raise exception 'the bare-name match does not say what it matched: key %, match_kind %',
            r->'rows'->0->>'key', r->'rows'->0->>'match_kind';
    end if;
    -- The kind-prefixed key still answers exactly, as before.
    if aiq.query('LOOKUP "project/harbour rewrite"')->'rows'->0->>'match_kind' is distinct from 'canonical' then
        raise exception 'the kind-prefixed key no longer answers as an exact match';
    end if;
    raise notice 'LOOKUP "Harbour Rewrite" -> project/harbour rewrite (soft)';
end $$;

-- 2. One name under two kinds is two rows, each naming its kind; and a name
--    that is nobody's is still unresolved.
do $$
declare r jsonb := aiq.query('LOOKUP "Lantern", "Nobody Here"');
begin
    if (select array_agg(x->>'key' order by x->>'key') from jsonb_array_elements(r->'rows') x)
       is distinct from '{place/lantern,project/lantern}' then
        raise exception 'LOOKUP "Lantern" should find both soft kinds: %', r->'rows';
    end if;
    if r->'unresolved' is distinct from '["Nobody Here"]'::jsonb then
        raise exception 'a name nobody holds should be unresolved: %', r->'unresolved';
    end if;
end $$;

-- 3. A typed node of the same name wins over the soft one.
insert into demo_t995_project (name) values ('Harbour Rewrite');
do $$
declare r jsonb := aiq.query('LOOKUP "Harbour Rewrite"');
begin
    if jsonb_array_length(r->'rows') is distinct from 1
       or r->'rows'->0->>'entity_type' is distinct from 'ttype_t995_project'
       or r->'rows'->0->>'match_kind' is distinct from 'canonical' then
        raise exception 'a typed node of the same name should win over the soft one: %', r->'rows';
    end if;
    raise notice 'with a typed node of the same name, LOOKUP answers the typed one';
end $$;

rollback;
