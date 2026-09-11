-- Packages: a domain installed as a document. See brief.md for the argument.
--
-- `percolate.apply_package(jsonb)` ORCHESTRATES rather than replaces:
-- `agentic.apply_plugin` still owns servers, skills and agents, keeps its
-- prune and keeps its unknown-key guard unchanged. This function owns the four
-- new sections and hands the three old ones straight through.
--
-- Not folded into one function, and the reason is that guard. apply_plugin
-- refuses a key it does not read, BECAUSE a manifest prunes what it does not
-- declare -- so a misspelt section is not a no-op, it is a removal. Widening
-- that function means widening the set of keys it will accept, and every key
-- added is a key a typo can hide in. Two functions, each strict about its own
-- half, is the smaller blast radius. Folding them is a later decision that
-- needs a reason.

create schema if not exists percolate;

-- WHAT A PACKAGE'S STORAGE MAY NOT ADD, checked in the catalog after it runs.
--
-- A package brings its own DDL (brief.md §3), and until 2026-09-11 nothing
-- looked at it. Each package wrote its own tenancy and grants, and the three
-- in this tree disagreed: pgvector-watch had an org foreign key, policies and
-- a revoke; percolate-dev and incident-review had a nullable org_id, no RLS and
-- no grants, and their manifests named no `org:`, so every row they projected
-- landed on the shared tier as public. On the tour database every pgw definer
-- function had a NULL ACL, which is PUBLIC's EXECUTE (REM-47; postmortem
-- 2026-09-11-fixed-at-the-copy-that-failed §2.2).
--
-- So the rules the core holds its own tables to are stated here for a schema
-- the extension does not own:
--
--   * no SECURITY DEFINER function PUBLIC can execute. A NULL ACL is PUBLIC's
--     default, so it is read through acldefault() rather than as "no grants";
--     dev/tests/rbac/04 reads it the same way.
--   * an org_id column is NOT NULL and defaults to rbac.shared_org_id(), which
--     is identity/checks.sql §5 for the core's tables.
--   * a table with org_id has row-level security on and at least one policy.
--
-- Every finding is reported in one error rather than the first. A storage file
-- that gets one of these wrong usually gets it wrong on every table, and
-- fixing them one run at a time is the loop apply.py's check_schema_refs
-- already refuses to make somebody sit through.
create or replace function percolate.check_package_schema(p_schema name)
returns void language plpgsql stable
set search_path = pg_catalog, public as $$
declare
    v_ns       oid := (select oid from pg_namespace where nspname = p_schema);
    v_problems text[];
begin
    -- A schema that is not there has nothing wrong with it, so a misspelt name
    -- would pass. Refused instead.
    if v_ns is null then
        raise exception 'package schema % does not exist', p_schema;
    end if;

    select array_agg(problem order by problem) into v_problems from (
        select format('%s is SECURITY DEFINER and PUBLIC can execute it', p.oid::regprocedure) as problem
          from pg_proc p
         where p.pronamespace = v_ns and p.prosecdef
           and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                        where a.grantee = 0 and a.privilege_type = 'EXECUTE')
        union all
        select format('%s.org_id is %s', c.oid::regclass,
                      case when not a.attnotnull then 'nullable'
                           else 'defaulted to ' || coalesce(pg_get_expr(d.adbin, d.adrelid), 'nothing')
                                || ', where the core defaults to rbac.shared_org_id()' end)
          from pg_class c
          join pg_attribute a on a.attrelid = c.oid and a.attname = 'org_id' and not a.attisdropped
          left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
         where c.relnamespace = v_ns and c.relkind in ('r', 'p')
           -- EXACT, not a pattern: pg_get_expr prints the call qualified under
           -- this function's search_path, so the text is fixed.
           and (not a.attnotnull
                or pg_get_expr(d.adbin, d.adrelid) is distinct from 'rbac.shared_org_id()')
        union all
        select format('%s has org_id and %s', c.oid::regclass,
                      case when not c.relrowsecurity then 'row-level security is off'
                           else 'no policy' end)
          from pg_class c
          join pg_attribute a on a.attrelid = c.oid and a.attname = 'org_id' and not a.attisdropped
         where c.relnamespace = v_ns and c.relkind in ('r', 'p')
           and (not c.relrowsecurity
                or not exists (select 1 from pg_policy pol where pol.polrelid = c.oid))
    ) f;

    if v_problems is not null then
        raise exception 'package schema % adds what the core would refuse:%', p_schema,
            E'\n  ' || array_to_string(v_problems, E'\n  ')
        using hint = 'A table with an org: select rbac.add_scope_columns(''<schema>.<table>''); '
                     'select rbac.add_scope_policy(''<schema>.<table>''); -- or, for a table '
                     'that keeps its own policy, rbac.adopt_shared_org(''<schema>.<table>''). '
                     'A definer function: revoke execute on function <fn> from public, and '
                     'grant it to the role that needs it.';
    end if;
end $$;

comment on function percolate.check_package_schema(name) is
    'Refuse a package schema holding a PUBLIC-executable SECURITY DEFINER function, '
    'an org_id that is nullable or not defaulted to rbac.shared_org_id(), or an '
    'org_id table without RLS and a policy. packages/apply.py runs it in the '
    'transaction that applies storage; apply_package runs it on every schema an '
    'entity type names.';

create or replace function percolate.apply_package(p_manifest jsonb)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare
    v_name    text := p_manifest->>'name';
    v_known   text[] := array['name','version','description','requires',
                              'entity_types','relations','sources',
                              'servers','skills','agents','workflows','extractors'];
    v_unknown text;
    v_e       jsonb;
    v_plugin  jsonb;
    v_out     jsonb := '{}'::jsonb;
    v_n       int;
    v_req     text;
    v_tbl     regclass;
begin
    if v_name is null or v_name = '' then
        raise exception 'a package manifest needs a name';
    end if;

    -- THE SAME GUARD, for the same reason. A key this function does not read
    -- is a mistake rather than an extension, and on a function that prunes it
    -- is a dangerous one.
    select string_agg(k, ', ') into v_unknown
      from jsonb_object_keys(p_manifest) k
     where k <> all(v_known);
    if v_unknown is not null then
        raise exception 'package %: unknown manifest key(s): %', v_name, v_unknown
        using hint = 'A manifest PRUNES what it does not declare, so a misspelt '
                     'key removes what the correct one installed. Known keys: '
                     || array_to_string(v_known, ', ');
    end if;

    -- REQUIRES, checked before anything opens. brief.md §7: without this a
    -- manifest applied to an older database fails at the first missing
    -- function, with an error naming the function rather than the requirement.
    v_req := p_manifest->>'requires';
    if v_req is not null then
        declare v_min text := regexp_replace(v_req, '^[^0-9]*', '');
               v_have text := (select extversion from pg_extension where extname='percolate');
        begin
            if string_to_array(v_have,'.')::int[] < string_to_array(v_min,'.')::int[] then
                raise exception 'package % requires percolate >= %, this database is %',
                    v_name, v_min, v_have;
            end if;
        end;
    end if;

    -- 1. VOCABULARY FIRST. A source cannot write a node before its entity type
    --    exists, and aiq.relation_types refuses an unlisted triple at write.
    v_n := 0;
    for v_e in select * from jsonb_array_elements(coalesce(p_manifest->'entity_types','[]'::jsonb))
    loop
        -- THE TABLE HAS TO EXIST, and saying so here is the difference between
        -- a requirement and a stack trace. A manifest declares entity types
        -- over tables it does not create -- storage belongs to whatever
        -- produces the rows, which for now is the package's worker image --
        -- and without this check the first missing one dies inside a generated
        -- trigger with `schema "pkg_dev" does not exist`, four frames down and
        -- naming neither the package nor the section.
        if to_regclass(v_e->>'table') is null then
            raise exception 'package %: entity type % declares table %, which does not exist',
                v_name, v_e->>'name', v_e->>'table'
            using hint = 'A package does not create its own storage: the worker '
                         'image that produces the rows owns the DDL, and it runs '
                         'before the manifest is applied. See specs/packages §3.';
        end if;
        v_tbl := to_regclass(v_e->>'table');

        -- THE STORAGE IS HELD TO THE CORE'S RULES HERE TOO, not only in
        -- apply.py. A client that applies storage its own way and then calls
        -- this function is still refused, before a projection trigger is
        -- attached to a table every tenant could read. Not over the
        -- extension's own schemas: identity/checks.sql and rbac/04 hold those,
        -- and rbac.org_members is the one table whose org_id is the tenancy
        -- itself rather than a scope, which the core exempts and a package
        -- never has.
        perform percolate.check_package_schema(n.nspname)
           from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where c.oid = v_tbl
            and not exists (select 1 from pg_depend dep
                             where dep.classid = 'pg_namespace'::regclass and dep.objid = n.oid
                               and dep.refclassid = 'pg_extension'::regclass and dep.deptype = 'e');

        -- THE ROW'S OWN SCOPE, UNLESS THE MANIFEST SAYS OTHERWISE. With no
        -- `org:` this passed 'null', and register_entity_table reads a null org
        -- as the shared tier and a shared-tier node as public: every row
        -- percolate-dev and incident-review would have projected was readable
        -- by every tenant, whatever org the row carried. A table with the
        -- column has already said where its rows belong. `visibility` for the
        -- same reason: a table scoped by rbac.add_scope_columns() carries it,
        -- and deriving it from the org instead turned a private row on the
        -- shared tier into a public node.
        perform aiq.register_entity_table(
            p_entity_type  => v_e->>'name',
            p_source_table => v_e->>'table',
            p_key_expr     => v_e->>'key',
            p_summary_expr => coalesce(v_e->>'summary', 'null'),
            p_org_expr     => coalesce(v_e->>'org',
                                  case when exists (select 1 from pg_attribute
                                                     where attrelid = v_tbl and attname = 'org_id'
                                                       and not attisdropped)
                                       then 'n.org_id' else 'null' end),
            p_include_where=> coalesce(v_e->>'where', 'true'),
            p_visibility_expr => coalesce(v_e->>'visibility',
                                  case when exists (select 1 from pg_attribute
                                                     where attrelid = v_tbl and attname = 'visibility'
                                                       and not attisdropped)
                                       then 'n.visibility' end));
        v_n := v_n + 1;
    end loop;
    v_out := v_out || jsonb_build_object('entity_types', v_n);

    v_n := 0;
    for v_e in select * from jsonb_array_elements(coalesce(p_manifest->'relations','[]'::jsonb))
    loop
        insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description)
        values (v_e->>0, v_e->>1, v_e->>2, v_e->>3,
                coalesce(v_e->>4, 'declared by package ' || v_name))
        on conflict (src_type, relation, dst_type) do update
            set inverse_label = excluded.inverse_label;
        v_n := v_n + 1;
    end loop;
    -- INTO THE MACHINE VOCABULARY, TOO, or the package cannot write its own
    -- relations. A package is mostly derivation (brief.md §8) and its knit and
    -- dream stages write edges through aiq.upsert_graph, which drops any
    -- relation that is not in aiq.graph_vocabulary. This used to call
    -- register_graph_vocabulary() with no payload -- the REFRESH form, which
    -- widens the cross product of relations already in the vocabulary and adds
    -- none -- so every relation a package declared was an authored triple its
    -- own derivations could never land: scenarios/tour's knit wrote 0 of its
    -- edges, each named in the receipt as an unknown relation. The inverse
    -- label travels with it, so a model reaching for `affected_by` is flipped
    -- onto `affects` rather than dropped.
    if v_n > 0 then
        perform aiq.register_graph_vocabulary((
            select jsonb_agg(jsonb_build_object(
                       'relation', r.relation, 'inverse_label', r.inverse_label,
                       'description', r.description))
              from (select e->>1 as relation, min(e->>3) as inverse_label,
                           min(coalesce(e->>4, 'declared by package ' || v_name)) as description
                      from jsonb_array_elements(p_manifest->'relations') e
                     group by e->>1) r));
    end if;
    v_out := v_out || jsonb_build_object('relations', v_n);

    -- 2. SOURCES.
    v_n := 0;
    for v_e in select * from jsonb_array_elements(coalesce(p_manifest->'sources','[]'::jsonb))
    loop
        -- WHERE NOT EXISTS rather than ON CONFLICT: content.channels is unique
        -- on (org_id, name) and a shared channel's org_id is the sentinel, so
        -- the conflict target is real -- but the insert site convention in
        -- world-model-ingestion is the guard, and a package should not be the
        -- one caller that does it differently.
        if v_e->>'kind'='http_pull' and v_e->'config' ? 'api' then
            if rbac.current_user_id() is null then
                raise exception 'An API source package needs an installation owner.'
                using hint = 'Use packages/apply.py --owner USER_UUID. The source and its runs belong to this user.';
            end if;
            if exists(select 1 from content.channels where name=v_e->>'name' and org_id=rbac.shared_org_id()
                      and (owner_id is distinct from rbac.current_user_id() or kind<>'http_pull' or config is distinct from v_e->'config')) then
                raise exception 'API source % already exists with different settings or ownership. Use a new source name or update it explicitly.',v_e->>'name';
            end if;
            insert into content.channels(name,kind,config,owner_id,visibility)
            select v_e->>'name','http_pull',v_e->'config',rbac.current_user_id(),'private'
            where not exists(select 1 from content.channels where name=v_e->>'name' and org_id=rbac.shared_org_id());
        else
        insert into content.channels (name, kind, config)
        select v_e->>'name', coalesce(v_e->>'kind','manual'),
               coalesce(v_e->'config','{}'::jsonb)
        where not exists (select 1 from content.channels c
                           where c.name = v_e->>'name'
                             and c.org_id = rbac.shared_org_id());
        end if;
        v_n := v_n + 1;
    end loop;
    v_out := v_out || jsonb_build_object('sources', v_n);

    -- 3. THE PLUGIN HALF, handed straight through with its own guard intact.
    v_plugin := jsonb_build_object('name', v_name)
             || coalesce(jsonb_build_object('version', p_manifest->>'version'), '{}'::jsonb)
             || (case when p_manifest ? 'servers' then jsonb_build_object('tool_servers', p_manifest->'servers') else '{}'::jsonb end)
             || (case when p_manifest ? 'skills'  then jsonb_build_object('skills',  p_manifest->'skills')  else '{}'::jsonb end)
             || (case when p_manifest ? 'agents'  then jsonb_build_object('agents',  p_manifest->'agents')  else '{}'::jsonb end);
    if p_manifest ? 'servers' or p_manifest ? 'skills' or p_manifest ? 'agents' then
        v_out := v_out || jsonb_build_object('plugin', agentic.apply_plugin(v_plugin));
    end if;

    -- 4. WORKFLOWS LAST. A sql: step names a registered function and an agent:
    --    step names an agent; the compiler lints both, so everything they name
    --    has to exist by now.
    v_n := 0;
    for v_e in select * from jsonb_array_elements(coalesce(p_manifest->'workflows','[]'::jsonb))
    loop
        perform workflow.define_yaml(v_e->>'yaml');
        if v_e ? 'schedule' then
            perform workflow.schedule_workflow(
                p_name     => (v_e->>'name') || '_sched',
                p_workflow => v_e->>'name',
                p_cron     => v_e->>'schedule',
                p_overlap  => 'skip');
        end if;
        v_n := v_n + 1;
    end loop;
    v_out := v_out || jsonb_build_object('workflows', v_n);

    -- EXTRACTORS ARE RECORDED, NOT RUN. brief.md §6: the image is the interim
    -- and the section is meant to empty. Storing what a package CLAIMS to
    -- provide is what makes "which extractors have earned promotion" a query
    -- rather than an argument.
    insert into agentic.plugins (name, version, description, manifest)
    values (v_name, coalesce(p_manifest->>'version','0.0.0'),
            p_manifest->>'description', p_manifest)
    on conflict (name) do update
        set version = excluded.version, description = excluded.description,
            manifest = excluded.manifest, updated_at = now();

    return v_out || jsonb_build_object('package', v_name,
                                       'extractors', jsonb_array_length(
                                          coalesce(p_manifest->'extractors'->'provides','[]'::jsonb)));
end $$;

-- Operator-only. It is SECURITY DEFINER and installs agents, tool servers,
-- sources and workflows, and it carried Postgres's PUBLIC default until
-- 2026-09-11 -- dev/tests/rbac/04 listed six schemas and this one was not among
-- them. packages/apply.py calls it as app_owner, which owns it.
revoke execute on function percolate.apply_package(jsonb) from public;

comment on function percolate.apply_package(jsonb) is
    'Install a package: vocabulary, sources, the plugin half, then workflows. '
    'Order is forced by existing constraints, not chosen. See specs/packages.';
