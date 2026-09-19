-- A CALLER READS A VECTOR ONLY IF THEY MAY READ ITS CHUNK (REM-567).
--
-- aiq.emb_<model> is granted to authenticated and api_viewer, because
-- semantic_in reads it as the caller. It had RLS off, so a direct select
-- returned every tenant's chunk ids and vectors. Each space now carries a read
-- policy through the registered sources (ai-query-layer/schema.sql §10a-iii).
--
--   1. A reads A's vector and not B's, directly and through SEMANTIC, as
--      authenticated and as api_viewer (the role a person's SQL step runs as);
--   2. B, symmetrically;
--   3. the control: with the space's RLS disabled, A's direct select returns
--      B's vector, so §1 and §2 can fail.
--
-- rbac/02 §10 is the class gate. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

insert into aiq.embedding_models (name, dim, is_default) values ('rem567-probe', 4, false);
select aiq.register_embedding_space('rem567-probe');

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000567a1', 'rem567-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000567b2', 'rem567-b@example.test', 'active');
insert into content.channels (id, name, kind, org_id, visibility)
    values ('00000000-0000-4000-8000-0000000567c0', 'rem567', 'manual', rbac.shared_org_id(), 'public');
insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility, owner_id) values
    ('00000000-0000-4000-8000-0000000567d1', '00000000-0000-4000-8000-0000000567c0', 'rem567-a',
     'memo://rem567/a', 'A''s memo', 'ready', rbac.shared_org_id(), 'private',
     '00000000-0000-4000-8000-0000000567a1'),
    ('00000000-0000-4000-8000-0000000567d2', '00000000-0000-4000-8000-0000000567c0', 'rem567-b',
     'memo://rem567/b', 'B''s memo', 'ready', rbac.shared_org_id(), 'private',
     '00000000-0000-4000-8000-0000000567b2');
insert into content.resource_chunks (id, resource_id, ordinal, content) values
    ('00000000-0000-4000-8000-0000000567e1', '00000000-0000-4000-8000-0000000567d1', 0, 'A''s chunk'),
    ('00000000-0000-4000-8000-0000000567e2', '00000000-0000-4000-8000-0000000567d2', 0, 'B''s chunk');
insert into aiq.emb_rem567_probe (chunk_id, embedding) values
    ('00000000-0000-4000-8000-0000000567e1', '[1,0,0,0]'),
    ('00000000-0000-4000-8000-0000000567e2', '[1,0.01,0,0]');
reset role;

do $$
begin
    if not (select relrowsecurity from pg_class where oid = 'aiq.emb_rem567_probe'::regclass) then
        raise exception 'register_embedding_space built a space with RLS off (REM-567)';
    end if;
end $$;

-- A probe per caller and role: what the space and the search each return.
create function pg_temp.rem567_probe(p_self text, p_other text) returns void as $$
declare
    own   uuid := ('00000000-0000-4000-8000-0000000567' || p_self)::uuid;
    other uuid := ('00000000-0000-4000-8000-0000000567' || p_other)::uuid;
begin
    if not exists (select 1 from aiq.emb_rem567_probe where chunk_id = own) then
        raise exception '% cannot read the vector of their own chunk as % -- the policy refuses the caller it is for',
            p_self, current_user;
    end if;
    if exists (select 1 from aiq.emb_rem567_probe where chunk_id = other) then
        raise exception '% read the vector of another user''s chunk from aiq.emb_rem567_probe as % (REM-567)',
            p_self, current_user;
    end if;
    if not exists (select 1 from aiq.semantic_in('chunks', '[1,0,0,0]', 'rem567-probe', 10) s
                    where s.chunk_id = own) then
        raise exception 'SEMANTIC as % does not return %''s own chunk', current_user, p_self;
    end if;
    if exists (select 1 from aiq.semantic_in('chunks', '[1,0,0,0]', 'rem567-probe', 10) s
                where s.chunk_id = other) then
        raise exception 'SEMANTIC as % returned another user''s chunk to % (REM-567)', current_user, p_self;
    end if;
end $$ language plpgsql;
grant execute on function pg_temp.rem567_probe(text, text) to authenticated;

-- 1. A.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000567a1"}';
set local role authenticated;
select pg_temp.rem567_probe('e1', 'e2');
reset role;
set local role api_viewer;
select pg_temp.rem567_probe('e1', 'e2');
reset role;
do $$ begin raise notice 'rbac/20: A reads A''s vector and not B''s, directly and through SEMANTIC'; end $$;

-- 2. B.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000567b2"}';
set local role authenticated;
select pg_temp.rem567_probe('e2', 'e1');
reset role;
set local role api_viewer;
select pg_temp.rem567_probe('e2', 'e1');
reset role;
do $$ begin raise notice 'rbac/20: B reads B''s vector and not A''s, directly and through SEMANTIC'; end $$;

-- 3. The control: without the space's RLS, A reads B's vector directly.
alter table aiq.emb_rem567_probe disable row level security;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000567a1"}';
set local role authenticated;
do $$
begin
    if not exists (select 1 from aiq.emb_rem567_probe
                    where chunk_id = '00000000-0000-4000-8000-0000000567e2') then
        raise exception 'with RLS off A still cannot read B''s vector, so §1 and §2 prove nothing';
    end if;
    raise notice 'rbac/20: control -- with RLS off, A reads B''s vector';
end $$;
reset role;

rollback;
