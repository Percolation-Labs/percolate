-- The lake: refinement after staging, in DuckDB, beside the bytes.
--
-- lake.md is the argument. This file is the half of it Postgres holds: which
-- datasets exist, where they are, what their columns MEAN when the storage
-- format cannot say, and who may read or write them. The worker holds the
-- object-storage credential and does the scanning; it decides nothing about
-- visibility. Every location a sandboxed DuckDB connection is allowed to touch
-- comes out of a function below, evaluated as the run owner.

-- ------------------------------------------------------------
-- 1. The columns are in schema.sql, beside the table they widen: table_ref,
-- geometry, embeddings, produced_by, inputs, and the wider format and mode
-- sets. content.dataset_uri is `language sql` and reads table_ref, and a
-- language-sql body is validated at create time, so the column has to exist
-- before that function does -- which puts it in schema.sql, not here.

-- ------------------------------------------------------------
-- 2. Where an org's lake outputs live. One place, so the worker that writes
-- and the function that registers cannot disagree about the layout.
--
-- Parquet: lake/<org>/<name>/..., under the deployment's lake bucket.
-- Iceberg: namespace o_<org hex>, one per org, so a table_ref names its tenant.
create or replace function content.lake_namespace(p_org_id uuid)
returns text as $$
    select 'o_' || replace(p_org_id::text, '-', '');
$$ language sql immutable;

create or replace function content.lake_prefix(p_org_id uuid, p_name text)
returns text as $$
    select 'lake/' || p_org_id::text || '/' || p_name;
$$ language sql immutable;
-- Internal: called by the definer functions below, never by a client. The
-- default EXECUTE-to-PUBLIC would put both on the external surface, and
-- surface.sql's undeclared-surface check refuses exactly that.
revoke all on function content.lake_namespace(uuid) from public;
revoke all on function content.lake_prefix(uuid, text) from public;

-- The run's org, for a task the caller currently holds. Outputs belong to the
-- org the run was started in, not to whichever org the owner happens to be in
-- most recently.
create or replace function content.lake_task_scope(p_task uuid, p_worker text)
returns table (owner_id uuid, org_id uuid) as $$
    select workflow.task_owner(p_task, p_worker), r.org_id
      from workflow.tasks t join workflow.runs r on r.id = t.run_id
     where t.id = p_task;
$$ language sql stable security definer set search_path = pg_catalog, public;
revoke all on function content.lake_task_scope(uuid, text) from public;

-- ------------------------------------------------------------
-- 3. Resolve: the datasets a caller may read, and where they are.
--
-- content.lake_datasets resolves names under whatever claims are current,
-- through rbac.may_read -- the one predicate every read path in the collection
-- uses. content.lake_resolve calls it for a workflow task after setting the
-- claims to the run owner's; a second copy of the visibility rule written for
-- the worker would be the one that drifted.
--
-- The explicit may_read predicate is not redundant with the table's RLS: a
-- SECURITY DEFINER caller (lake_resolve) runs this as the table owner, which
-- bypasses RLS, and the predicate is then the whole of the check.
--
-- One message for "does not exist" and "may not read": a function that told
-- them apart would be an existence oracle over other tenants' dataset names.
create or replace function content.lake_datasets(p_names text[])
returns jsonb as $$
declare
    v_out  jsonb := '[]'::jsonb;
    v_name text;
    d      content.datasets;
begin
    foreach v_name in array coalesce(p_names, '{}') loop
        select * into d from content.datasets x
         where x.name = v_name
           and rbac.may_read(x.owner_id, x.org_id, x.visibility)
         -- dataset_uri's ordering: the tenant's own beats the shared tier.
         order by (x.org_id = rbac.shared_org_id())
         limit 1;
        if not found then
            raise exception 'dataset % does not exist, or the run owner may not read it', v_name
                using errcode = '42501';
        end if;
        v_out := v_out || jsonb_build_object(
            'name', d.name, 'format', d.format, 'bucket', d.bucket,
            'prefix', d.prefix, 'table_ref', d.table_ref, 'columns', d.columns,
            'geometry', d.geometry, 'embeddings', d.embeddings,
            'row_count', d.row_count, 'mode', d.mode, 'updated_at', d.updated_at);
    end loop;
    return v_out;
end;
$$ language plpgsql stable security invoker set search_path = pg_catalog, public;
revoke all on function content.lake_datasets(text[]) from public;
-- No grant: lake_resolve is its only caller, and runs as the owner.

-- For a workflow task: the same resolution, as the run owner. The claims are
-- set transaction-local for the call and put back, because this runs inside
-- the worker's own transaction.
create or replace function content.lake_resolve(p_task uuid, p_worker text, p_names text[])
returns jsonb as $$
declare
    v_scope  record;
    v_claims text := current_setting('request.jwt.claims', true);
    v_out    jsonb;
begin
    select * into v_scope from content.lake_task_scope(p_task, p_worker);
    perform set_config('request.jwt.claims',
                       jsonb_build_object('sub', v_scope.owner_id)::text, true);
    v_out := content.lake_datasets(p_names);
    perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
    return v_out;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;
revoke all on function content.lake_resolve(uuid, text, text[]) from public;
grant execute on function content.lake_resolve(uuid, text, text[]) to worker;

-- The existing dataset an output would write into, if there is one -- and a
-- refusal if the run owner may not write it, or if the output would change
-- what it IS. One function, called by lake_target (so the worker learns where
-- to write before it writes) and by register_lake_output (which is where the
-- rule is enforced). Two copies of this check would drift, and the one that
-- drifted would be the one nobody runs.
create or replace function content.lake_existing(p_owner uuid, p_org uuid, p_name text, p_format text)
returns content.datasets as $$
declare
    v_claims text := current_setting('request.jwt.claims', true);
    v_old    content.datasets;
begin
    select * into v_old from content.datasets where org_id = p_org and name = p_name;
    if not found then
        return null;
    end if;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', p_owner)::text, true);
    if not rbac.may_write(v_old.owner_id, v_old.org_id, v_old.visibility)
       or (v_old.owner_id is not null and v_old.owner_id <> p_owner) then
        raise exception 'dataset % exists and the run owner may not write it', p_name
            using errcode = '42501';
    end if;
    perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
    if p_format is not null and v_old.format <> p_format then
        raise exception 'dataset % is %; an % output cannot take its name',
            p_name, v_old.format, p_format;
    end if;
    return v_old;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;
revoke all on function content.lake_existing(uuid, uuid, text, text) from public;

-- Where this task may write a named output. Returned rather than computed in
-- the worker, so the layout has exactly one definition.
create or replace function content.lake_target(p_task uuid, p_worker text, p_name text,
                                               p_format text default 'parquet')
returns jsonb as $$
declare
    v_scope record;
    v_old   content.datasets;
begin
    if p_name is null or p_name !~ '^[a-z][a-z0-9_]{0,62}$' then
        raise exception 'a lake output name is a lowercase identifier (letters, digits, underscore), got %', p_name;
    end if;
    select * into v_scope from content.lake_task_scope(p_task, p_worker);
    v_old := content.lake_existing(v_scope.owner_id, v_scope.org_id, p_name, p_format);
    return jsonb_build_object(
        'org_id', v_scope.org_id,
        'prefix', content.lake_prefix(v_scope.org_id, p_name),
        'namespace', content.lake_namespace(v_scope.org_id),
        'table_ref', content.lake_namespace(v_scope.org_id) || '.' || p_name,
        'existing', case when v_old.id is null then null else
            jsonb_build_object('prefix', v_old.prefix, 'mode', v_old.mode,
                               'row_count', v_old.row_count) end);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;
revoke all on function content.lake_target(uuid, text, text, text) from public;
grant execute on function content.lake_target(uuid, text, text, text) to worker;

-- ------------------------------------------------------------
-- 4. Register what a refine step wrote.
--
-- THE REGISTRY IS WHAT THE SANDBOX TRUSTS, so it refuses a location outside
-- the writing org's own prefix or namespace. lake_resolve hands these paths to
-- DuckDB's allow-list; a row in org A pointing into org B's prefix would make
-- B's files readable to every workflow in A. The worker holds a credential
-- that can reach both, so the refusal has to live here, not in the worker.
create or replace function content.register_lake_output(p_task uuid, p_worker text, p_out jsonb)
returns jsonb as $$
declare
    v_scope   record;
    v_name    text := p_out->>'name';
    v_format  text := coalesce(p_out->>'format', 'parquet');
    v_mode    text := coalesce(p_out->>'mode', 'append');
    v_prefix  text := p_out->>'prefix';
    v_ref     text := nullif(p_out->>'table_ref', '');
    v_emb     jsonb := coalesce(p_out->'embeddings', '{}'::jsonb);
    v_col     text;
    v_spec    jsonb;
    v_dim     int;
    v_old     content.datasets;
    v_id      uuid;
begin
    select * into v_scope from content.lake_task_scope(p_task, p_worker);
    if v_name is null or v_name !~ '^[a-z][a-z0-9_]{0,62}$' then
        raise exception 'a lake output name is a lowercase identifier, got %', v_name;
    end if;

    if v_format = 'parquet' then
        -- starts_with and not LIKE: `_` is a LIKE wildcard and every lake
        -- name may contain one. And no dot segments at all, because DuckDB's
        -- allow-list compares strings -- `…/name/../../<other org>/` starts
        -- with an allowed directory, and whether the store then normalises
        -- the path is up to the store (MinIO refused it; an HTTP layer that
        -- follows RFC 3986 would not).
        if v_prefix is null
           or v_prefix ~ '(^|/)\.\.?(/|$)'
           or not (v_prefix = content.lake_prefix(v_scope.org_id, v_name)
                   or starts_with(v_prefix, content.lake_prefix(v_scope.org_id, v_name) || '/')) then
            raise exception 'a parquet output for % must live under %, not %',
                v_name, content.lake_prefix(v_scope.org_id, v_name), v_prefix
                using errcode = '42501';
        end if;
        v_ref := null;
    elsif v_format = 'iceberg' then
        if v_ref is distinct from content.lake_namespace(v_scope.org_id) || '.' || v_name then
            raise exception 'an iceberg output for % must be %, not %',
                v_name, content.lake_namespace(v_scope.org_id) || '.' || v_name, v_ref
                using errcode = '42501';
        end if;
    end if;

    -- The model names the space, here as in aiq: a column claiming a model
    -- that is not registered, or a width that model does not produce, would
    -- let a query vector from one space rank against another with no error.
    for v_col, v_spec in select * from jsonb_each(v_emb) loop
        select dim into v_dim from aiq.embedding_models where name = v_spec->>'model';
        if v_dim is null then
            raise exception 'column % names embedding model %, which is not registered',
                v_col, v_spec->>'model';
        end if;
        if (v_spec->>'dims')::int is distinct from v_dim then
            raise exception 'column % has % dimensions and model % produces %',
                v_col, v_spec->>'dims', v_spec->>'model', v_dim;
        end if;
    end loop;

    -- An existing dataset of this name in this org: the owner may replace its
    -- contents only if they may write it, and never change what it IS.
    v_old := content.lake_existing(v_scope.owner_id, v_scope.org_id, v_name, v_format);

    insert into content.datasets (name, org_id, owner_id, visibility, bucket, prefix,
                                  format, mode, table_ref, columns, row_count,
                                  file_count, geometry, embeddings, produced_by, inputs)
    values (v_name, v_scope.org_id, v_scope.owner_id,
            coalesce(p_out->>'visibility', 'private'),
            p_out->>'bucket', v_prefix, v_format, v_mode, v_ref,
            coalesce(p_out->'columns', '[]'::jsonb),
            coalesce((p_out->>'row_count')::bigint, 0),
            coalesce((p_out->>'file_count')::int, 0),
            coalesce(p_out->'geometry', '{}'::jsonb), v_emb, p_task,
            coalesce((select array_agg(x) from jsonb_array_elements_text(p_out->'inputs') x), '{}'))
    on conflict (org_id, name) do update
        set prefix = excluded.prefix, bucket = excluded.bucket, mode = excluded.mode,
            columns = excluded.columns, row_count = excluded.row_count,
            file_count = excluded.file_count, geometry = excluded.geometry,
            embeddings = excluded.embeddings, produced_by = excluded.produced_by,
            inputs = excluded.inputs, updated_at = now()
    returning id into v_id;

    return jsonb_build_object('dataset_id', v_id, 'name', v_name, 'format', v_format,
                              'mode', v_mode, 'prefix', v_prefix, 'table_ref', v_ref);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;
revoke all on function content.register_lake_output(uuid, text, jsonb) from public;
grant execute on function content.register_lake_output(uuid, text, jsonb) to worker;

-- ------------------------------------------------------------
-- 5. Land: rows that crossed from the lake into Postgres.
--
-- The worker holds no table grants, so a refined result reaches a table only
-- through a function. Which functions: the ones in workflow.step_functions
-- whose signature is (task uuid, worker text, rows jsonb) -- the same registry
-- that answers "what can a workflow cause to run" for sql steps, with its
-- existence and reachability checks already on the table. The landing
-- function is handed the task and worker so it can ask task_owner() who the
-- rows belong to, exactly as content.commit_api_page does.
--
-- The worker enforces the step's max_rows before the first call; the per-call
-- cap here is the database's own bound on one transaction, and it holds
-- whatever the worker does.
create or replace function content.lake_land(p_task uuid, p_worker text, p_function text, p_rows jsonb)
returns jsonb as $$
declare
    v_fn  workflow.step_functions;
    v_out jsonb;
begin
    perform workflow.task_owner(p_task, p_worker);
    select * into v_fn from workflow.step_functions where name = p_function;
    if not found then
        raise exception 'no step function named % -- register it with workflow.register_step_function', p_function;
    end if;
    if v_fn.arg_types is distinct from array['uuid', 'text', 'jsonb'] then
        raise exception 'step function % takes (%), and a landing function takes (uuid, text, jsonb): the task, the worker, and the rows',
            p_function, array_to_string(v_fn.arg_types, ', ');
    end if;
    if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 10000 then
        raise exception 'a landing batch is a json array of at most 10,000 rows';
    end if;
    execute format('select to_jsonb(%s($1, $2, $3))', v_fn.fn)
       into v_out using p_task, p_worker, p_rows;
    return v_out;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;
revoke all on function content.lake_land(uuid, text, text, jsonb) from public;
grant execute on function content.lake_land(uuid, text, text, jsonb) to worker;

-- ------------------------------------------------------------
-- 6. Discovery, as the caller.

-- Discovery. What a model needs to write a query -- names, columns, types,
-- sizes, which columns are vectors in which space, which are shapes in which
-- CRS -- and not where the bytes are: a storage location is for the lake
-- worker, and lake_resolve hands it over only for a task that names it.
-- `strpos`, not ILIKE, so a search for `ship_` is a substring and not a pattern.
create or replace function content.lake_catalog(p_search text default null, p_limit int default 50)
returns jsonb as $$
    with visible as (
        select d.* from content.datasets d
         where rbac.may_read(d.owner_id, d.org_id, d.visibility)
           and (p_search is null
                or strpos(lower(d.name), lower(p_search)) > 0
                or strpos(lower(d.columns::text), lower(p_search)) > 0)
    ), page as (
        select * from visible
         order by updated_at desc
         limit least(greatest(coalesce(p_limit, 50), 1), 200)
    )
    select jsonb_build_object(
        'total', (select count(*) from visible),
        'datasets', coalesce((select jsonb_agg(jsonb_build_object(
            'name', name, 'format', format, 'columns', columns,
            'row_count', row_count, 'file_count', file_count,
            'geometry', geometry, 'embeddings', embeddings,
            'inputs', inputs, 'updated_at', updated_at) order by updated_at desc)
          from page), '[]'::jsonb));
$$ language sql stable security invoker set search_path = pg_catalog, public;
revoke all on function content.lake_catalog(text, int) from public;
grant execute on function content.lake_catalog(text, int) to authenticated;


-- ------------------------------------------------------------
-- 7. p8ql: LAKE, and SCHEMA "lake".
--
-- `LAKE FROM <dataset> [, ...] <select>` is a p8ql mode (the parser crate's
-- parse_lake). aiq.query hands its plan here. The datasets are resolved AS THE
-- CALLER, and a name that does not resolve is reported in `unresolved` rather
-- than raised -- LOOKUP's convention, so an agent learns which name was wrong
-- instead of receiving an error about the whole query.
--
-- NOTHING IS EXECUTED, and the envelope says so and says where it runs. The
-- plan carries what a model needs to check its SQL before a workflow runs it
-- -- each dataset's columns and types, which columns are vectors in which
-- space, which are shapes in which CRS -- and not where the bytes are.
create or replace function content.lake_plan(p jsonb)
returns jsonb as $$
    with asked as (
        select a.name, a.ord from jsonb_array_elements_text(p->'sources') with ordinality a(name, ord)
    ), found as (
        select a.name, a.ord, d.format, d.columns, d.row_count, d.embeddings, d.geometry
          from asked a
          left join lateral (
              select x.* from content.datasets x
               where x.name = a.name and rbac.may_read(x.owner_id, x.org_id, x.visibility)
               order by (x.org_id = rbac.shared_org_id())
               limit 1) d on true
    )
    select jsonb_build_object(
        'mode', 'LAKE', 'plan', p, 'statement', p->>'arg', 'rows', '[]'::jsonb,
        'datasets', coalesce((select jsonb_agg(jsonb_build_object(
                        'name', name, 'format', format, 'columns', columns,
                        'row_count', row_count, 'embeddings', embeddings,
                        'geometry', geometry) order by ord)
                      from found where format is not null), '[]'::jsonb),
        'unresolved', coalesce((select jsonb_agg(name order by ord)
                                  from found where format is null), '[]'::jsonb),
        'executed', false,
        'note', 'a LAKE query runs on the lake worker, not in Postgres: write it as a '
                '`p8ql:` step in a workflow and read {{steps.<id>.result.rows}}');
$$ language sql stable security invoker set search_path = pg_catalog, public;
revoke all on function content.lake_plan(jsonb) from public;
grant execute on function content.lake_plan(jsonb) to authenticated, worker;

-- The facet. Caller-scoped, because two callers see different datasets -- the
-- p8ql facet is global and versioned by hash, so the list lives here and not
-- there. `SCHEMA "lake"` searches (FROM is a substring of a dataset or column
-- name); every dataset carries its columns, which is what writing the SQL
-- needs.
create or replace function content.schema_lake(p_name text default null)
returns jsonb as $$
    select jsonb_build_object(
        'query_with', 'LAKE FROM <dataset> [, <dataset> ...] <select> -- DuckDB SQL, each dataset a table under its own name',
        'runs_on', 'the lake worker, as a p8ql: step in a workflow; aiq.query returns the plan',
        'datasets', content.lake_catalog(p_name, 200));
$$ language sql stable security invoker set search_path = pg_catalog, public;
revoke all on function content.schema_lake(text) from public;
grant execute on function content.schema_lake(text) to authenticated;

select aiq.register_schema_facet('lake', 'content.schema_lake',
    'Datasets in the lake',
    'Parquet and Iceberg datasets in object storage that you may read: columns and types, '
    'row counts, which columns are vectors (in which embedding model''s space) and which '
    'are shapes (in which CRS). Query them with LAKE. Narrow with FROM <substring>.', true);
select aiq.register_schema_example('lake', 'lake-aggregate', 'p8ql',
    'LAKE FROM sales select region, sum(amount) as total from sales group by 1 order by 2 desc',
    'aggregate in the lake and bring back the answer, not the rows', 10);
