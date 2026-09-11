-- A SECURITY DEFINER function a person can call asks the ROW's question.
--
-- Definer functions run past RLS, so each one has to ask whether the caller may
-- touch the row it is about to touch, by name. Several asked the ORG's
-- question instead -- rbac.may_access_org, "may this person act inside that
-- tenancy" -- which a co-member, and on the shared tier anybody, answers yes.
-- content.resolve_file moved to rbac.may_read in 75abb1d; its siblings stayed
-- (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §1, REM-46).
-- Three more were worker plumbing granted to `authenticated` with no check at
-- all, where the grant is the only authorization there is.
--
-- The subject is a private upload and a private agent of alice's, in an org bob
-- also belongs to. So the org rule says yes to bob, and only the row rule can
-- say no -- a fixture where bob was a stranger would pass under the org rule
-- and prove nothing. Each refusal is paired with alice being served, so a
-- function that stopped answering anyone cannot pass for one that answers
-- correctly. One transaction, rolled back: the seat changes inside it.

\set ON_ERROR_STOP on

-- 1. Worker plumbing is the worker's: the grant is its authorization.
do $$
declare f text;
begin
    foreach f in array array[
        'workflow.register_artifact(uuid,text,text,text,bigint,text,text,uuid)',
        'workflow.execute_sql_step(uuid)',
        'workflow.drain_sql_steps(uuid,int)']
    loop
        if has_function_privilege('authenticated', f, 'execute') then
            raise exception
                '% is executable by authenticated, and it asks nothing about whose run '
                'or task it is given', f;
        end if;
        if not has_function_privilege('worker', f, 'execute') then
            raise exception '% is not executable by worker, its caller', f;
        end if;
    end loop;
    raise notice 'rbac/13: register_artifact, execute_sql_step and drain_sql_steps are the worker''s alone';
end $$;

begin;

-- 2. The fixture: one org with both of them in it; alice's private resource
--    with two chunks, and alice's private agent.
create temp table t13 (org uuid, res uuid, agent text);
grant select on t13 to public;
insert into t13 values (gen_random_uuid(), null, 't13-agent-' || left(gen_random_uuid()::text, 8));
do $$
declare o uuid := (select org from t13); v uuid;
begin
    insert into rbac.orgs (id, slug, name) values (o, 't13-' || left(o::text, 8), 'rbac/13 org');
    insert into rbac.org_members (org_id, user_id) values
        (o, '11111111-1111-1111-1111-111111111111'),
        (o, '22222222-2222-2222-2222-222222222222');
    insert into content.channels (name, kind, org_id, visibility)
    values ('t13-uploads', 'file_upload', o, 'org');
    insert into agentic.agents (name, model, owner_id, org_id, visibility)
    values ((select agent from t13), 'gpt-4o-mini',
            '11111111-1111-1111-1111-111111111111', o, 'private');

    execute format('set local request.jwt.claims = %L', '{"sub":"11111111-1111-1111-1111-111111111111"}');
    v := content.register_upload('t13-uploads', 't13-' || gen_random_uuid(), 'bucket', 't13/one',
                                 10, 'text/plain', 'alice only', null, o);
    perform content.record_chunks(v,
        '[{"content":"alice''s first chunk"},{"content":"alice''s second chunk"}]'::jsonb);
    -- Private, which an upload into an org is not by default. The fixture's
    -- own write, as the table's owner, so it states what it means.
    update content.resources set visibility = 'private' where id = v;
    update t13 set res = v;
end $$;

-- 3. Reading chunks: bob is refused; alice and the worker are served.
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
begin
    -- A missing fixture returns '[]' from both functions, which is the answer
    -- this block expects -- so the subject is asserted first.
    if (select res from t13) is null then
        raise exception 'the fixture resource is missing -- bob''s refusal would pass vacuously';
    end if;
    if content.chunks_to_embed((select res from t13)) <> '[]'::jsonb then
        raise exception 'chunks_to_embed handed bob the text of alice''s private resource';
    end if;
    if content.windows_to_index((select res from t13)) <> '[]'::jsonb then
        raise exception 'windows_to_index handed bob the text of alice''s private resource';
    end if;
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$
begin
    if jsonb_array_length(content.chunks_to_embed((select res from t13))) <> 2
       or jsonb_array_length(content.windows_to_index((select res from t13))) <> 2 then
        raise exception 'alice is no longer served her own chunks';
    end if;
end $$;
reset role;

set local request.jwt.claims = '';   -- the worker's embed fan-out carries no person
do $$
begin
    if jsonb_array_length(content.chunks_to_embed((select res from t13))) <> 2 then
        raise exception 'a claimless caller (the worker) is no longer served the chunks it embeds';
    end if;
    raise notice 'rbac/13: a co-member cannot read a private resource''s chunks; its owner and the worker can';
end $$;

-- 4. Replacing chunks: bob is refused, and alice's chunks are what they were.
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_err text;
begin
    begin
        perform content.record_chunks((select res from t13), '[{"content":"bob was here"}]'::jsonb);
    exception when others then v_err := sqlerrm;
    end;
    if v_err is null then
        raise exception 'record_chunks let bob replace the chunks of alice''s private resource';
    end if;
end $$;
reset role;
do $$
declare v_res uuid := (select res from t13);
begin
    if v_res is null then
        raise exception 'the fixture resource is missing -- nothing below would test anything';
    end if;
    if (select count(*) from content.resource_chunks
         where resource_id = v_res and content like 'alice%') <> 2 then
        raise exception 'alice''s chunks changed under a refused call';
    end if;
    raise notice 'rbac/13: a co-member cannot replace a private resource''s chunks';
end $$;

-- 5. The workflow schema facet lists the agents the caller may read.
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_agent text := (select agent from t13);
begin
    if v_agent is null then
        raise exception 'the fixture agent is missing -- bob''s refusal would pass vacuously';
    end if;
    if exists (select 1 from jsonb_array_elements(aiq.schema_workflow()->'derived'->'agents') a
                where a->>'name' = v_agent) then
        raise exception 'aiq.schema_workflow listed alice''s private agent to bob';
    end if;
end $$;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$
declare v_agent text := (select agent from t13);
begin
    if not exists (select 1 from jsonb_array_elements(aiq.schema_workflow()->'derived'->'agents') a
                    where a->>'name' = v_agent) then
        raise exception 'aiq.schema_workflow no longer lists alice''s own agent to her';
    end if;
    raise notice 'rbac/13: the workflow facet lists only agents the caller may read';
end $$;
reset role;

-- 6. The graph facet's sample keys are keys the caller may read.
--
-- aiq.schema_graph shows up to three canonical keys per entity type, and it
-- scoped them by hand as "the nodes_org_scoped policy written out": shared
-- tier or one of the caller's orgs. The policy became nodes_scoped, on owner
-- and visibility, and the copy did not follow -- the sibling of every section
-- above, found by declaring how each reachable definer authorizes (rbac/14,
-- REM-46). Alice's private node in the org she shares with bob, keyed to sort
-- first so that it is one of the three whenever it is visible at all.
do $$
declare v uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, owner_id, org_id, visibility)
    values ('document', gen_random_uuid(), '11111111-1111-1111-1111-111111111111',
            (select org from t13), 'private')
    returning id into v;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    values (v, 'document', '0000-t13-alice-private', 'canonical', (select org from t13));
end $$;

create temp view t13_sample_keys as
select k.key
  from jsonb_array_elements(aiq.schema_graph('document')->'derived'->'entity_types') e,
       jsonb_array_elements_text(e->'sample_keys') k(key);
grant select on t13_sample_keys to public;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$
begin
    -- The subject first: if alice cannot see her own key here, bob not seeing
    -- it below says nothing.
    if not exists (select 1 from t13_sample_keys where key = '0000-t13-alice-private') then
        raise exception 'aiq.schema_graph does not show alice her own node''s key -- the '
                        'refusal below would pass vacuously';
    end if;
end $$;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
begin
    if exists (select 1 from t13_sample_keys where key = '0000-t13-alice-private') then
        raise exception 'aiq.schema_graph showed bob the key of alice''s private node';
    end if;
    raise notice 'rbac/13: the graph facet samples only keys the caller may read';
end $$;
reset role;

rollback;
