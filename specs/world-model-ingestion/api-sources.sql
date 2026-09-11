-- Incremental API sources. Configuration travels in a package; progress does not.
create table if not exists content.source_state (
    source_id uuid primary key references content.channels(id) on delete cascade,
    revision bigint not null default 0,
    watermark text,
    pending_watermark text,
    next_url text,
    visited_urls jsonb not null default '[]',
    last_page_hash text,
    active_task uuid references workflow.tasks(id),
    last_completed_task uuid references workflow.tasks(id),
    last_receipt jsonb,
    pages int not null default 0,
    inserted int not null default 0,
    updated int not null default 0,
    unchanged int not null default 0,
    total_records bigint not null default 0,
    last_page_at timestamptz,
    last_completed_at timestamptz
);
create table if not exists content.source_records (
    source_id uuid not null references content.channels(id) on delete cascade,
    external_id text not null,
    watermark text,
    raw jsonb not null,
    data jsonb not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key(source_id,external_id)
);
alter table content.source_state enable row level security;
alter table content.source_records enable row level security;
drop policy if exists source_read on content.source_state;
create policy source_read on content.source_state for select using (exists(select 1 from content.channels c where c.id=source_id));
drop policy if exists source_read on content.source_records;
create policy source_read on content.source_records for select using (exists(select 1 from content.channels c where c.id=source_id));
grant select on content.source_state,content.source_records to authenticated,api_viewer;

create or replace function content.save_api_source(p_id uuid,p_name text,p_config jsonb,p_queue text,p_updated_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_user uuid:=rbac.current_user_id(); old content.channels; c content.channels; w jsonb; a jsonb:=p_config->'api'; n text:='source_'||replace(p_id::text,'-','');
begin
 if v_user is null or not workflow.may_define() then raise exception 'Saving an API source requires workflows:update.' using errcode='42501';end if;
 if p_id is null or p_name is null or p_name !~ '^[a-z][a-z0-9_-]{0,63}$' then raise exception 'Use a source name starting with a lowercase letter, with up to 64 letters, numbers, hyphens or underscores.';end if;
 if jsonb_typeof(a) is distinct from 'object' or coalesce(a->>'url','') !~ '^https?://' or coalesce(a->>'id_path','')='' then raise exception 'An API source needs an HTTP(S) endpoint and a record ID field.';end if;
 if coalesce(a->>'auth_type','none') not in ('none','bearer','header') or
    coalesce(a->>'pagination','none') not in ('none','link_header','next_url','page_token','page') or
    coalesce(a->>'watermark_type','none') not in ('none','timestamp','number') then raise exception 'Unsupported authentication, pagination or watermark type.';end if;
 if a ? 'token' or a ? 'secret' or a ? 'password' or exists(select 1 from jsonb_object_keys(coalesce(a->'headers','{}')) k where lower(k) in ('authorization','cookie','x-api-key','api-key')) then
  raise exception 'Store authentication by credential reference, never as a token or literal authentication header.';end if;
 if p_queue is null or p_queue !~ '^[a-zA-Z0-9_:/.-]+$' then raise exception 'Choose an ingestion worker queue.';end if;
 select * into old from content.channels where id=p_id for update;
 if found then
  if old.owner_id is distinct from v_user then raise exception 'Only the owner can update this source. Create a private copy.' using errcode='42501';end if;
  if old.kind<>'http_pull' then raise exception 'Create a new source to change its type.';end if;
  if p_updated_at is distinct from old.updated_at then raise exception 'The source changed since you opened it. Reopen it before saving; your draft is preserved.' using errcode='PT409';end if;
  if old.config->'api' is distinct from a and exists(select 1 from content.source_state where source_id=p_id and (watermark is not null or next_url is not null)) then
   raise exception 'This source has saved progress. Create a new source for a different ingestion configuration, or reset its progress first.';end if;
  if exists(select 1 from workflow.runs r join workflow.definitions d on d.id=r.workflow_def_id where d.name in (n,old.config->>'ingest_workflow') and r.status='running') then raise exception 'Wait for the active pull to finish before changing this source.';end if;
 elsif exists(select 1 from workflow.definitions where name=n) then raise exception 'That workflow identity already exists. Create a new source.';
 end if;
 if exists(select 1 from content.channels where name=p_name and org_id=rbac.shared_org_id() and id<>p_id) then raise exception 'That source name is already in use.';end if;
 w:=jsonb_build_object('name',n,'steps',jsonb_build_array(jsonb_build_object('id','pull','work',true,'queue',p_queue,'input',jsonb_build_object('op','api_pull','source_id',p_id))));
 perform workflow.define_yaml(w::text);
 insert into content.channels(id,name,kind,config,owner_id,visibility,org_id)
 values(p_id,p_name,'http_pull',p_config||jsonb_build_object('ingest_workflow',n,'workflow',w),v_user,'private',rbac.shared_org_id())
 on conflict(id) do update set name=excluded.name,config=excluded.config,updated_at=clock_timestamp()
 returning * into c;
 return to_jsonb(c);
end $$;
revoke all on function content.save_api_source(uuid,text,jsonb,text,timestamptz) from public;
grant execute on function content.save_api_source(uuid,text,jsonb,text,timestamptz) to authenticated;

create or replace function content.start_source_pull(p_source_id uuid,p_external_id text default null)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare c content.channels; r uuid;
begin
 select * into c from content.channels where id=p_source_id for update;
 if c.id is null or rbac.current_user_id() is null or c.owner_id is distinct from rbac.current_user_id() then raise exception 'Only the source owner can start this pull.' using errcode='42501';end if;
 if c.kind<>'http_pull' or not c.enabled then raise exception 'This API source is not enabled.';end if;
 select x.id into r from workflow.runs x join workflow.definitions d on d.id=x.workflow_def_id
 where d.name=c.config->>'ingest_workflow' and x.status='running' order by x.created_at desc limit 1;
 if r is not null then return r;end if;
 return workflow.start_workflow(c.config->>'ingest_workflow','{}',p_external_id);
end $$;
revoke all on function content.start_source_pull(uuid,text) from public;
grant execute on function content.start_source_pull(uuid,text) to authenticated;

create or replace function content.begin_api_pull(p_task uuid,p_worker text,p_source uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_owner uuid; c content.channels; s content.source_state;
begin
 v_owner:=workflow.task_owner(p_task,p_worker);
 select * into c from content.channels where id=p_source for update;
 if c.owner_id is distinct from v_owner or c.kind<>'http_pull' or not c.enabled then raise exception 'This run cannot pull the requested API source.' using errcode='42501';end if;
 insert into content.source_state(source_id) values(p_source) on conflict do nothing;
 select * into s from content.source_state where source_id=p_source for update;
 if s.last_completed_task=p_task then return jsonb_build_object('complete',true,'receipt',s.last_receipt);end if;
 if s.active_task is not null and s.active_task<>p_task and exists(select 1 from workflow.tasks where id=s.active_task and status='running') then raise exception 'Another task is pulling this source; retry after it finishes.' using errcode='40001';end if;
 update content.source_state set active_task=p_task,
  pages=case when next_url is null then 0 else pages end,
  inserted=case when next_url is null then 0 else inserted end,
  updated=case when next_url is null then 0 else updated end,
  unchanged=case when next_url is null then 0 else unchanged end
 where source_id=p_source returning * into s;
 return to_jsonb(s)||jsonb_build_object('config',c.config->'api');
end $$;
revoke all on function content.begin_api_pull(uuid,text,uuid) from public;
grant execute on function content.begin_api_pull(uuid,text,uuid) to worker;

create or replace function content.commit_api_page(p_task uuid,p_worker text,p_source uuid,p_revision bigint,p_records jsonb,p_url text,p_next text,p_watermark text,p_hash text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_owner uuid; s content.source_state; c content.channels; v jsonb; old content.source_records; ni int:=0;nu int:=0;ns int:=0;receipt jsonb;
begin
 v_owner:=workflow.task_owner(p_task,p_worker);
 select * into c from content.channels where id=p_source for update;
 if c.owner_id is distinct from v_owner then raise exception 'This task does not own the source.' using errcode='42501';end if;
 select * into s from content.source_state where source_id=p_source for update;
 if s.source_id is null or s.active_task is distinct from p_task or s.revision<>p_revision then raise exception 'Source progress changed; retry from the current checkpoint.' using errcode='40001';end if;
 if jsonb_typeof(p_records) is distinct from 'array' or jsonb_array_length(p_records)>10000 then raise exception 'A page must contain at most 10,000 records.';end if;
 for v in select * from jsonb_array_elements(p_records) loop
  if coalesce(v->>'external_id','')='' or jsonb_typeof(v->'data') is distinct from 'object' or jsonb_typeof(v->'raw') is distinct from 'object' then raise exception 'Each record needs an ID, original object and transformed object.';end if;
  select * into old from content.source_records where source_id=p_source and external_id=v->>'external_id';
  if not found then
   insert into content.source_records(source_id,external_id,watermark,raw,data) values(p_source,v->>'external_id',v->>'watermark',v->'raw',v->'data');ni:=ni+1;
  elsif old.watermark is not null and v->>'watermark' is not null and (case c.config->'api'->>'watermark_type'
    when 'timestamp' then (v->>'watermark')::timestamptz < old.watermark::timestamptz
    when 'number' then (v->>'watermark')::numeric < old.watermark::numeric
    else false end) then
   ns:=ns+1; -- A delayed older version cannot replace a newer stored record.
  elsif old.raw is distinct from v->'raw' or old.data is distinct from v->'data' then
   update content.source_records set raw=v->'raw',data=v->'data',watermark=v->>'watermark',updated_at=clock_timestamp() where source_id=p_source and external_id=v->>'external_id';nu:=nu+1;
  else ns:=ns+1;end if;
 end loop;
 receipt:=jsonb_build_object('source_id',p_source,'pages',s.pages+1,'inserted',s.inserted+ni,'updated',s.updated+nu,'unchanged',s.unchanged+ns,'watermark',p_watermark,'has_more',false,'status','complete');
 update content.source_state set revision=revision+1,next_url=p_next,
  pending_watermark=case when p_next is null then null else p_watermark end,
  watermark=case when p_next is null then p_watermark else watermark end,
  visited_urls=case when p_next is null then '[]'::jsonb else visited_urls||jsonb_build_array(p_url) end,
  last_page_hash=case when p_next is null then null else p_hash end,
  pages=pages+1,inserted=inserted+ni,updated=updated+nu,unchanged=unchanged+ns,total_records=total_records+ni,
  last_page_at=clock_timestamp(),last_completed_at=case when p_next is null then clock_timestamp() else last_completed_at end,
  last_completed_task=case when p_next is null then p_task else last_completed_task end,
  last_receipt=case when p_next is null then receipt else last_receipt end
 where source_id=p_source;
 return jsonb_build_object('revision',s.revision+1,'inserted',ni,'updated',nu,'unchanged',ns,'receipt',receipt);
end $$;
revoke all on function content.commit_api_page(uuid,text,uuid,bigint,jsonb,text,text,text,text) from public;
grant execute on function content.commit_api_page(uuid,text,uuid,bigint,jsonb,text,text,text,text) to worker;

create or replace function content.reset_source_progress(p_source_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare c content.channels;
begin
 select * into c from content.channels where id=p_source_id for update;
 if c.owner_id is distinct from rbac.current_user_id() or rbac.current_user_id() is null or not workflow.may_define() then raise exception 'Only the source author can reset its progress.' using errcode='42501';end if;
 if exists(select 1 from workflow.runs r join workflow.definitions d on d.id=r.workflow_def_id where d.name=c.config->>'ingest_workflow' and r.status='running') then raise exception 'Wait for the active run before resetting progress.';end if;
 update content.source_state set watermark=null,pending_watermark=null,next_url=null,visited_urls='[]',last_page_hash=null,active_task=null,last_completed_task=null,revision=revision+1 where source_id=p_source_id;
end $$;
revoke all on function content.reset_source_progress(uuid) from public;
grant execute on function content.reset_source_progress(uuid) to authenticated;

-- Portable package workflows resolve a source by name under the verified run
-- owner. Never resolve a private feed using a caller-supplied owner or org.
create or replace function content.begin_named_api_pull(p_task uuid,p_worker text,p_name text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare u uuid; c content.channels;
begin
 u:=workflow.task_owner(p_task,p_worker);
 select * into c from content.channels where name=p_name and owner_id=u and org_id=rbac.shared_org_id();
 if c.id is null then raise exception 'No owned API source with that name. Install the package for the run owner.' using errcode='42501';end if;
 return content.begin_api_pull(p_task,p_worker,c.id)||jsonb_build_object('source_id',c.id);
end $$;
revoke all on function content.begin_named_api_pull(uuid,text,text) from public;
grant execute on function content.begin_named_api_pull(uuid,text,text) to worker;
