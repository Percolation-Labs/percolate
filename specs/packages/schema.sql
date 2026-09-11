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
        perform aiq.register_entity_table(
            p_entity_type  => v_e->>'name',
            p_source_table => v_e->>'table',
            p_key_expr     => v_e->>'key',
            p_summary_expr => coalesce(v_e->>'summary', 'null'),
            p_org_expr     => coalesce(v_e->>'org', 'null'),
            p_include_where=> coalesce(v_e->>'where', 'true'));
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
