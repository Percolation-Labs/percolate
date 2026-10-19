-- AN EMBEDDING SPACE A SUPERUSER REGISTERS CAN STILL BE WRITTEN AND READ BY ITS USERS (REM-1009).
--
-- get-percolate's ingest.md registers the model from psql as the superuser,
-- and a space is created as its caller. On 0.2.23 that left
-- aiq.emb_<model> owned by `p8`: a member's first register_text failed with
-- "permission denied for table emb_..." (the content plane maintains vectors
-- as app_owner), and the space had none of app_owner's default grants, so
-- police_embedding_spaces wrote no read policy and SEARCH refused everyone.
-- Measured on a compose stack built from percolate main 60b46e45.
--
-- WHAT WOULD MAKE IT FAIL. Remove the hand-over in register_embedding_space
-- and §1 raises (owner p8, no policy), then §2 raises 42501.

\set ON_ERROR_STOP on
\set maya '''00000000-0000-0000-0000-00000010a9a1'''
\set leo  '''00000000-0000-0000-0000-00000010a9b1'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-00000010a9a1"}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-00000010a9b1"}''; set local role authenticated;'

begin;

-- Setup as the extension's owner, as any deployment does.
set local role app_owner;
insert into rbac.users (id, email) values (:maya, 'maya@rem1009.test'), (:leo, 'leo@rem1009.test');
insert into rbac.roles (name) values ('rem1009_member') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rem1009_member', 'resources', 'create')
on conflict do nothing;
insert into rbac.user_roles values (:maya, 'rem1009_member'), (:leo, 'rem1009_member') on conflict do nothing;
insert into content.channels (name, kind, org_id, visibility)
    values ('rem1009', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;
insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
    values ('rem1009-3d', 3, null, 'vector_cosine_ops', false, 'written by hand');
reset role;

-- The registration, as the documentation does it: from psql, as the superuser.
select aiq.register_embedding_space('rem1009-3d') \g /dev/null

-- 1. The space belongs to app_owner and reads through a policy.
do $$
declare v_owner text; v_pols text;
begin
    select tableowner into v_owner from pg_tables where schemaname = 'aiq' and tablename = 'emb_rem1009_3d';
    select string_agg(polname, ' ' order by polname) into v_pols
      from pg_policy where polrelid = 'aiq.emb_rem1009_3d'::regclass;
    if v_owner is distinct from 'app_owner' then
        raise exception 'a space the superuser registered is owned by %, not app_owner', v_owner;
    end if;
    if v_pols is null or v_pols not like '%space_read_authenticated%' then
        raise exception 'a space the superuser registered has no read policy for authenticated: %', v_pols;
    end if;
end $$;

-- 2. A member writes text; the vector is stored; she finds it and Leo does not.
:as_maya
select (content.register_text('rem1009', 'r1009-note', '[{"content":"Maya travels by train."}]')->>'resource_id') as note \gset
reset role;
set local role app_owner;
insert into aiq.emb_rem1009_3d (chunk_id, embedding)
select id, '[1,0,0]' from content.resource_chunks where resource_id = :'note';
reset role;

:as_maya
select jsonb_array_length(aiq.query('SEMANTIC "train" FROM chunks USING rem1009-3d', '[1,0,0]')->'rows') as maya_finds \gset
:as_leo
select jsonb_array_length(aiq.query('SEMANTIC "train" FROM chunks USING rem1009-3d', '[1,0,0]')->'rows') as leo_finds \gset
reset role;
select set_config('rem1009.maya', :'maya_finds', true), set_config('rem1009.leo', :'leo_finds', true) \g /dev/null
do $$
begin
    if current_setting('rem1009.maya')::int is distinct from 1 or current_setting('rem1009.leo')::int is distinct from 0 then
        raise exception 'Maya finds % of her own vectors (expected 1) and Leo finds % (expected 0)',
            current_setting('rem1009.maya'), current_setting('rem1009.leo');
    end if;
    raise notice 'a space the superuser registered: Maya writes and finds her note, Leo finds nothing';
end $$;

rollback;
