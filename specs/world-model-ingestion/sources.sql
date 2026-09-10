-- Data Sources authoring: a private channel and its workflow saved atomically.
-- Loads after ingestion.sql. Workflow authoring remains an explicit privilege.
create or replace function content.save_source(
    p_id uuid, p_name text, p_config jsonb, p_workflow jsonb,
    p_updated_at timestamptz default null
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.current_user_id();
    v_old content.channels;
    v_row content.channels;
    v_definition uuid;
    v_workflow text := 'source_' || replace(p_id::text, '-', '');
begin
    if v_user is null or not workflow.may_define() then
        raise exception 'Saving a data source requires workflows:update.' using errcode='42501';
    end if;
    if p_id is null or p_name is null or p_name !~ '^[a-z][a-z0-9_-]{0,63}$' then
        raise exception 'Use a source name of 1–64 lowercase letters, numbers, underscores or hyphens, starting with a letter.';
    end if;
    if jsonb_typeof(p_config) is distinct from 'object'
       or exists(select 1 from jsonb_object_keys(p_config) k where k not in ('description','ingest_policy','editor'))
       or jsonb_typeof(p_config->'ingest_policy') is distinct from 'object' then
        raise exception 'A source needs a description, ingestion policy and editor settings.';
    end if;
    if jsonb_typeof(p_workflow) is distinct from 'object'
       or p_workflow->>'name' is distinct from v_workflow then
        raise exception 'The workflow name must belong to this source: %', v_workflow;
    end if;
    -- Lock before comparing the revision: a second editor cannot silently win.
    select * into v_old from content.channels where id=p_id for update;
    if found then
        if v_old.owner_id is distinct from v_user then
            raise exception 'Only the owner can update this source. Create a new source instead.' using errcode='42501';
        end if;
        if p_updated_at is distinct from v_old.updated_at then
            raise exception 'This source changed since you opened it. Reopen it before saving; your draft is still available.' using errcode='40001';
        end if;
    elsif exists(select 1 from workflow.definitions where name=v_workflow) then
        raise exception 'That workflow name is already in use. Create a new source.';
    end if;
    if exists(select 1 from content.channels where org_id=rbac.shared_org_id() and name=p_name and id<>p_id) then
        raise exception 'That source name is already in use. Choose another name.';
    end if;
    v_definition := workflow.define_yaml(p_workflow::text);
    insert into content.channels(id,name,kind,config,owner_id,visibility,org_id)
    values(p_id,p_name,'file_upload',p_config || jsonb_build_object('ingest_workflow',v_workflow,'workflow',p_workflow),v_user,'private',rbac.shared_org_id())
    on conflict(id) do update set name=excluded.name, config=excluded.config, updated_at=clock_timestamp()
    returning * into v_row;
    return to_jsonb(v_row) || jsonb_build_object('definition_id',v_definition);
end;
$$;
revoke all on function content.save_source(uuid,text,jsonb,jsonb,timestamptz) from public;
grant execute on function content.save_source(uuid,text,jsonb,jsonb,timestamptz) to authenticated;

-- Bound arguments, and a verified run owner, rather than interpolated SQL or
-- a worker-wide corpus read. Only the engine invokes this registered function.
create or replace function content.source_passages(p_resource_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public as $$
declare
    v_owner uuid;
    v_rows jsonb;
    v_chars bigint;
begin
    select owner_id into v_owner from workflow.runs
      where id=nullif(current_setting('workflow.current_run_id',true),'')::uuid;
    if v_owner is null or not exists (
        select 1 from content.resources r where r.id=p_resource_id and (
            r.owner_id=v_owner or r.visibility='public' or
            (r.visibility='org' and r.org_id<>rbac.shared_org_id() and exists(
                select 1 from rbac.org_members m where m.org_id=r.org_id and m.user_id=v_owner)))) then
        raise exception 'This run cannot read the source document.' using errcode='42501';
    end if;
    select sum(length(content)) into v_chars from content.resource_chunks where resource_id=p_resource_id;
    if coalesce(v_chars,0)=0 then
        raise exception 'This document has no text passages. Use the text ingestion mode for an AI transformation.';
    end if;
    if v_chars>80000 then
        raise exception 'This document exceeds the 80,000-character transformation limit. Split it into smaller documents or author a workflow that processes windows.';
    end if;
    select jsonb_agg(jsonb_build_object('chunk_id',id,'resource_id',resource_id,'content',content) order by ordinal)
      into v_rows from content.resource_chunks where resource_id=p_resource_id;
    return jsonb_build_object('rows',v_rows);
end;
$$;
revoke all on function content.source_passages(uuid) from public;
select workflow.register_step_function('source_passages','content.source_passages',array['uuid'],30000,
    'Read one source document for its run owner; refuses empty or oversized text.');
