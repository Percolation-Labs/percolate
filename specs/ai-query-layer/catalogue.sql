-- ============================================================
-- The database's own catalogue, as nodes and exact edges.
--
-- An anchor that JOINS rather than matches. Text-derived edges between a
-- document and the thing it talks about are a `position()` over prose; this
-- makes the same relationship a join on a catalogue identity, and then derives
-- the dependency graph from `pg_depend` -- which is exact, complete, and
-- maintained by Postgres rather than inferred from traces the way a commercial
-- test-impact product has to.
--
-- OPT-IN, AND THAT IS THE WHOLE DESIGN. Nothing here runs at install: the table
-- ships empty and `aiq.refresh_catalogue()` is a call. A deployment that does
-- not want its own schema in its graph gets an empty table and pays nothing,
-- and one that does gets it without writing 300 lines of pg_catalog joins that
-- every such application would otherwise write again.
--
-- WHAT IS DELIBERATELY NOT HERE. Anything that links a catalogue object to a
-- document, a claim, an incident or a test. Those relations are how a
-- particular application talks about its own database, and the useful thing
-- core can offer is the anchor they attach to.
-- ============================================================

-- ONE ROW PER QUALIFIED NAME, and overloads are an attribute.
--
-- The first version of this was one row per signature and the load failed on
-- the canonical-key unique index: a canonical key is unique per entity type, so
-- two overloads of one function cannot be two nodes. That is not a bug to work
-- around, it is the identity model disagreeing with a surface that keeps
-- `f(uuid,jsonb)` and `f(uuid,jsonb,boolean)` apart precisely because they are
-- DIFFERENT PROMISES. So the graph knows a named surface and the row knows the
-- signatures, and a claim anchored here is anchored to the name.
create table if not exists aiq.db_objects (
    id          uuid generated always as (md5(ident)::uuid) stored primary key,
    ident       text not null unique,      -- schema-qualified, or the bare name for a role
    nspname     text not null,             -- '' for a role, which has no schema
    objname     text not null,
    kind        text not null,             -- function|table|view|matview|column|index|role
    oids        oid[] not null,            -- every overload
    signatures  text[] not null default '{}',
    n_overloads int  not null default 1,
    reachable   boolean not null default false,
    grantees    text[] not null default '{}'
);

-- NO org_id, AND THAT IS A DECISION. Sixteen tables in this extension carry one
-- and this is not the seventeenth: a database's own catalogue is one shared
-- fact about the installation, not a per-tenant one. There is no sense in which
-- `aiq.edges` belongs to an org. Giving it a column would have meant either an
-- RLS policy over data that has no owner, or a nullable column nobody sets --
-- and the second is how "org_id IS NULL" came to mean two different things
-- elsewhere in this schema.
--
-- Readable by everyone who can reach the schema, for the same reason: it
-- describes the database, and anybody connected to it can already ask
-- pg_catalog the same questions more slowly.
grant select on aiq.db_objects to authenticated, api_viewer;

comment on table aiq.db_objects is
    'This database''s own catalogue as rows, populated on demand by '
    'aiq.refresh_catalogue(). Empty until something asks for it.';

-- THE SCHEMAS AND THE ROLES ARE PARAMETERS.
--
-- An earlier version of this lived in an application and hardcoded seven schema
-- names and three role names. The schemas were that application's idea of "what
-- we own" and the roles were this extension's, and neither is a fact about a
-- deployment: somebody installs into a schema we have never heard of, or adds a
-- fourth reader role, and a hardcoded list is silently wrong rather than loudly
-- so. The defaults are what this extension ships with, which is what a default
-- is for.
--
-- `reachable` is scoped BY REACHABILITY, not by type: "every function" is a
-- list nobody can finish and a check that gets disabled; "what a caller can
-- execute or select" is the external surface exactly.
create or replace function aiq.refresh_catalogue(
    p_schemas text[] default array['aiq','rbac','workflow','content',
                                   'agentic','percolate'],
    p_reader_roles text[] default array['authenticated','web_anon','api_viewer'])
returns jsonb
language plpgsql security invoker as $$
declare n_obj int; n_dep int;
begin
    -- Functions, folded over their overloads, with the roles that may execute any.
    insert into aiq.db_objects
           (ident, nspname, objname, kind, oids, signatures, n_overloads,
            reachable, grantees)
    select n.nspname || '.' || p.proname, n.nspname, p.proname, 'function',
           array_agg(p.oid),
           array_agg(pg_get_function_identity_arguments(p.oid)),
           count(*),
           bool_or(exists (select 1 from pg_roles r
                           where r.rolname = any(p_reader_roles)
                             and has_function_privilege(r.oid, p.oid, 'execute'))),
           coalesce(array_agg(distinct g.grantee) filter (where g.grantee is not null), '{}')
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    left join lateral (
        select r.rolname as grantee from pg_roles r
        where r.rolname = any(p_reader_roles)
          and has_function_privilege(r.oid, p.oid, 'execute')
    ) g on true
    where n.nspname = any(p_schemas)
    group by n.nspname, p.proname
    on conflict (ident) do nothing;

    -- Tables and views, with the roles that may select them.
    insert into aiq.db_objects
           (ident, nspname, objname, kind, oids, reachable, grantees)
    select n.nspname || '.' || c.relname, n.nspname, c.relname,
           case c.relkind when 'v' then 'view' when 'm' then 'matview'
                          else 'table' end,
           array_agg(c.oid),
           bool_or(exists (select 1 from pg_roles r
                           where r.rolname = any(p_reader_roles)
                             and has_table_privilege(r.oid, c.oid, 'select'))),
           coalesce(array_agg(distinct g.grantee) filter (where g.grantee is not null), '{}')
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    left join lateral (
        select r.rolname as grantee from pg_roles r
        where r.rolname = any(p_reader_roles)
          and has_table_privilege(r.oid, c.oid, 'select')
    ) g on true
    where n.nspname = any(p_schemas) and c.relkind in ('r','v','m','p')
    group by n.nspname, c.relname, c.relkind
    on conflict (ident) do nothing;

    -- COLUMNS, INDEXES AND ROLES, because prose names them and a resolver
    -- cannot match what the catalogue does not contain. Measured before these
    -- were added: two thirds of backticked mentions in one repository's
    -- postmortems escalated to a model, and the largest recoverable group was
    -- exactly these three.
    --
    -- `objname` for a column is `table.column`, so nspname || objname still
    -- reconstructs ident.
    insert into aiq.db_objects
           (ident, nspname, objname, kind, oids, reachable, grantees)
    select n.nspname || '.' || c.relname || '.' || a.attname,
           n.nspname, c.relname || '.' || a.attname, 'column',
           array[c.oid],
           exists (select 1 from pg_roles r
                   where r.rolname = any(p_reader_roles)
                     and has_column_privilege(r.oid, c.oid, a.attnum, 'select')),
           coalesce((select array_agg(distinct r.rolname) from pg_roles r
                     where r.rolname = any(p_reader_roles)
                       and has_column_privilege(r.oid, c.oid, a.attnum, 'select')),
                    '{}')
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = any(p_schemas) and c.relkind in ('r','v','m','p')
      and a.attnum > 0 and not a.attisdropped
    on conflict (ident) do nothing;

    -- `reachable` is false by construction for an index: it is never something
    -- a caller selects or executes, it is how the planner answers when they do.
    insert into aiq.db_objects
           (ident, nspname, objname, kind, oids, reachable, grantees)
    select n.nspname || '.' || c.relname, n.nspname, c.relname, 'index',
           array[c.oid], false, '{}'
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = any(p_schemas) and c.relkind = 'i'
    on conflict (ident) do nothing;

    -- A role has no schema, so nspname is empty rather than borrowed from
    -- somewhere it does not belong; inventing a namespace to keep a column
    -- non-null would read as a fact.
    insert into aiq.db_objects
           (ident, nspname, objname, kind, oids, reachable, grantees)
    select r.rolname, '', r.rolname, 'role', array[r.oid], false, '{}'
    from pg_roles r
    where r.rolname not like 'pg\_%'
    on conflict (ident) do nothing;

    select count(*) into n_obj from aiq.db_objects;

    -- The entity type, registered here rather than at install: the projection
    -- trigger is only worth building for a deployment that populates the table.
    perform aiq.register_entity_table(
        p_entity_type  => 'db_object',
        p_source_table => 'aiq.db_objects',
        -- The bare qualified name, because that is what a person types and what
        -- a document writes. The signatures stay on the row: two overloads are
        -- two signatures and one key, which a lookup correctly returns as one
        -- node.
        p_key_expr     => 'n.ident',
        p_summary_expr => 'n.kind || '' '' || n.ident',
        p_org_expr     => 'null');

    -- Rows inserted BEFORE the registration built the trigger did not project,
    -- and a missing trigger is not an error. Rebuild rather than hope.
    perform aiq.rebuild_entity_type('db_object');

    insert into aiq.relation_types
           (src_type, relation, dst_type, inverse_label, description)
    -- THE DESCRIPTION DOES NOT CLAIM EXACTNESS, and that is deliberate. The
    -- edges THIS function writes are exact -- pg_depend and pg_constraint are
    -- maintained by Postgres -- but the relation is the general one, and an
    -- application is free to add heuristic edges under it from a function body
    -- that names an object, or from prose. Provenance is where a reader learns
    -- which they are holding: `kind` is 'exact' or 'textual' and `from` names
    -- the derivation. A relation type that promises exactness on behalf of
    -- every future writer is a promise the registry cannot keep.
    values ('db_object','depends_on','db_object','depended_on_by',
            'dropping the target would break the source. Read provenance.kind '
            'for whether a given edge is exact (pg_depend, pg_constraint) or '
            'textual')
    on conflict (src_type, relation, dst_type) do update
        set inverse_label = excluded.inverse_label,
            description   = excluded.description;
    perform aiq.register_graph_vocabulary();

    -- A VIEW DEPENDS ON WHAT IT SELECTS FROM, via pg_rewrite.
    --
    -- RESTRICTED TO RELATIONS AT BOTH ENDS, and the restriction is not
    -- cosmetic. A column row carries its TABLE's oid -- it has no oid of its
    -- own worth storing -- so `d.refobjid = any(t.oids)` matches every column
    -- of a table as well as the table, and a view reading one table acquires an
    -- edge to each of its columns. Measured on the corpus this was written
    -- against: 33,272 of 37,145 dependency edges pointed at a column, which is
    -- ninety per cent of the dependency graph being an artefact of how columns
    -- are keyed.
    insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
    select distinct nv.id, nt.id, 'depends_on', 1.0,
           '{"kind":"exact","from":"pg_depend via pg_rewrite"}'::jsonb
    from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid and d.classid = 'pg_rewrite'::regclass
    join aiq.db_objects v on rw.ev_class = any(v.oids)
                         and v.kind in ('view','matview')
    join aiq.db_objects t on d.refobjid = any(t.oids)
                         and d.refclassid = 'pg_class'::regclass
                         and t.kind in ('table','view','matview')
    join aiq.nodes nv on nv.entity_type = 'db_object' and nv.entity_id = v.id
    join aiq.nodes nt on nt.entity_type = 'db_object' and nt.entity_id = t.id
    where v.ident <> t.ident
    on conflict (src_id, dst_id, relation) do update
        set weight = excluded.weight, provenance = excluded.provenance,
            valid_to = null;

    -- AND A FOREIGN KEY IS A DEPENDENCY TOO, and pg_depend does not spell it
    -- the same way.
    insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
    select distinct ns.id, nt.id, 'depends_on', 1.0,
           '{"kind":"exact","from":"pg_constraint foreign key"}'::jsonb
    from pg_constraint c
    join aiq.db_objects s on c.conrelid = any(s.oids)
                         and s.kind in ('table','view','matview')
    join aiq.db_objects t on c.confrelid = any(t.oids)
                         and t.kind in ('table','view','matview')
    join aiq.nodes ns on ns.entity_type = 'db_object' and ns.entity_id = s.id
    join aiq.nodes nt on nt.entity_type = 'db_object' and nt.entity_id = t.id
    where c.contype = 'f' and s.ident <> t.ident
    on conflict (src_id, dst_id, relation) do update
        set weight = excluded.weight, provenance = excluded.provenance,
            valid_to = null;

    select count(*) into n_dep from aiq.edges_current
     where relation = 'depends_on';

    return jsonb_build_object('objects', n_obj, 'depends_on', n_dep);
end $$;

comment on function aiq.refresh_catalogue(text[], text[]) is
    'Project this database''s own catalogue into the graph, with exact '
    'dependency edges from pg_depend and pg_constraint. Opt-in: nothing runs '
    'until this is called.';
