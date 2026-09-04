-- THE CONTENT PLANE, EXECUTED -- and the tenancy hole that found.
--
-- `world-model-ingestion` is marked **Built** and had no test directory at
-- all. Every capability it declares was present in surface.sql and unexercised
-- by anything, which is how the defect in §5 survived: the READ path was
-- scoped correctly the whole time, so every question anyone had asked -- can
-- this tenant see that? -- got the right answer.
--
-- Nobody had asked what a tenant could WRITE.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- Two tenants, two channels, and a caller identity that is a request-scoped
-- claim rather than a role -- which is what the deployment actually does:
-- PostgREST connects as one login role and sets the verified JWT per request.
create temp table t_ctx (org_a uuid, org_b uuid, res_a uuid);
insert into t_ctx values (gen_random_uuid(), gen_random_uuid(), null);

do $$
declare a uuid; b uuid;
begin
    select org_a, org_b into a, b from t_ctx;
    insert into content.channels (name, kind, org_id) values ('t-uploads', 'file_upload', a);
    insert into content.channels (name, kind, org_id) values ('t-uploads', 'file_upload', b);
    insert into content.channels (name, kind, org_id) values ('t-feed', 'feed', a);
end $$;

-- ---------------------------------------------------------------------
-- 1. Upload, resolve, chunk, search -- the whole flow, in one transaction.
--
-- The last assertion is the one that ties the two subsystems together: a chunk
-- recorded through the content plane must be findable through the query layer
-- immediately, with no reindex step and nothing deployed.
-- ---------------------------------------------------------------------
do $$
declare
    a uuid; v_res uuid; v_n int; r record;
begin
    select org_a into a from t_ctx;
    v_res := content.register_upload('t-uploads', 't-sum-1', 'bucket', 'keys/one',
                                     4096, 'text/plain', 'Outage postmortem', null, a);
    update t_ctx set res_a = v_res;

    if (select status from content.resources where id = v_res) is distinct from 'pending' then
        raise exception 'a freshly registered resource is not pending';
    end if;

    select * into r from content.resolve_file(v_res);
    if r.bucket is distinct from 'bucket' or r.object_key is distinct from 'keys/one' then
        raise exception 'resolve_file did not return the storage location';
    end if;

    if content.record_chunks(v_res,
        '[{"content":"the quixotic flywheel assembly overheats under sustained load"},
          {"content":"a second chunk, about something else entirely"}]'::jsonb) <> 2 then
        raise exception 'record_chunks did not report the rows it wrote';
    end if;
    if (select status from content.resources where id = v_res) is distinct from 'ready' then
        raise exception 'recording chunks did not flip the resource ready';
    end if;

    select count(*) into v_n from aiq.lexical('chunks', 'quixotic flywheel', 5);
    if v_n < 1 then
        raise exception
            'a chunk recorded a statement ago is not lexically searchable -- the content '
            'plane and the query layer have come apart';
    end if;
    raise notice 'content/01: upload -> resolve -> chunk -> searchable, in one transaction with nothing deployed';
end $$;

-- ---------------------------------------------------------------------
-- 2. Dedup is by content hash; idempotency is by (channel, external_id).
--
-- Two different properties that look like one until the same bytes arrive
-- under two names, which is the ordinary case for a document mailed twice.
-- ---------------------------------------------------------------------
do $$
declare a uuid; v_1 uuid; v_2 uuid; v_3 uuid;
begin
    select org_a into a from t_ctx;
    v_1 := content.register_upload('t-uploads','t-dup','b','k/a',10,null,'first', null,a,'{}'::jsonb,'ext-1');
    v_2 := content.register_upload('t-uploads','t-dup','b','k/b',10,null,'second',null,a,'{}'::jsonb,'ext-2');

    if (select count(*) from content.files where checksum = 't-dup') <> 1 then
        raise exception 'the same bytes under two names produced two file rows';
    end if;
    if (select count(distinct file_id) from content.resources where id in (v_1, v_2)) <> 1 then
        raise exception 'two resources of one checksum do not share a file';
    end if;

    v_3 := content.register_upload('t-uploads','t-other','b','k/c',10,null,'again',null,a,'{}'::jsonb,'ext-1');
    if v_3 is distinct from v_1 then
        raise exception 'the same external_id created a second resource -- a re-poll would fork';
    end if;

    -- ...and a fetched item with no bytes returns NULL the second time, which
    -- a puller must read as "already had it" rather than as an error.
    if content.register_fetched('t-feed','feed-1','title',null,a) is null then
        raise exception 'the first sighting of a feed item returned nothing';
    end if;
    if content.register_fetched('t-feed','feed-1','title',null,a) is not null then
        raise exception 'a second poll of the same item registered it twice';
    end if;
    raise notice 'content/01: one checksum is one file, one external_id is one resource, a re-poll is a no-op';
end $$;

-- ---------------------------------------------------------------------
-- 3. A channel naming a workflow that does not exist takes the upload with it.
--
-- register_upload starts the ingestion run in the SAME transaction as the rows
-- deliberately, so that a committed resource always has a run. The corollary
-- is worth asserting: a channel misconfiguration fails the upload rather than
-- landing a resource nothing will ever chunk.
-- ---------------------------------------------------------------------
do $$
declare a uuid; v_ok boolean := false;
begin
    select org_a into a from t_ctx;
    insert into content.channels (name, kind, org_id, config)
    values ('t-broken','file_upload', a, '{"ingest_workflow":"no_such_workflow"}'::jsonb);
    begin
        perform content.register_upload('t-broken','t-b','b','k/b',1,null,null,null,a);
    exception when others then
        v_ok := true;
    end;
    if not v_ok then
        raise exception 'an upload into a channel with an unknown ingest_workflow succeeded';
    end if;
    if (select count(*) from content.resources r join content.channels c on c.id = r.channel_id
         where c.name = 't-broken') <> 0 then
        raise exception 'the failed upload left a resource behind';
    end if;
    raise notice 'content/01: a channel pointing at a workflow that does not exist fails the upload, and leaves nothing';
end $$;

-- ---------------------------------------------------------------------
-- 4. Drift reports what the database can see, and only that.
-- ---------------------------------------------------------------------
do $$
declare a uuid; v_res uuid; v_file uuid;
begin
    select org_a into a from t_ctx;

    -- a resource marked ready with nothing in it: record_chunks was called
    -- with an empty list, which is exactly what a chunker that produced
    -- nothing does
    v_res := content.register_upload('t-uploads','t-empty','b','k/e',10,null,'empty',null,a);
    perform content.record_chunks(v_res, '[]'::jsonb);
    if not exists (select 1 from content.check_drift() d
                    where d.id = v_res and d.kind = 'ready_but_empty') then
        raise exception 'a ready resource with no chunks is not reported as drift';
    end if;

    -- a file no resource points at: the upload transaction died after storing
    insert into content.files (checksum, bucket, object_key, size_bytes)
    values ('t-orphan','b','k/orphan',1) returning id into v_file;
    if not exists (select 1 from content.check_drift() d
                    where d.id = v_file and d.kind = 'orphan_file') then
        raise exception 'a file with no resource is not reported as drift';
    end if;

    raise notice 'content/01: drift finds a ready-but-empty resource and an orphaned file';
end $$;

-- ---------------------------------------------------------------------
-- 5. WHAT A TENANT MAY WRITE, which is the question nobody had asked.
--
-- All three writers are SECURITY DEFINER and granted to `authenticated`, and
-- none of them checked anything. Measured, as an ordinary logged-in user of
-- org B holding only org A's resource uuid:
--
--     org B can SEE org A's resource: false
--     org B REWROTE org A's chunks
--     org B PLANTED a resource in org A's channel
--
-- record_chunks DELETEs every chunk of the resource it is handed, so that is
-- destruction and injection in one call, into the corpus SEMANTIC and SEARCH
-- read -- an agent asking its own tenant's documents a question would retrieve
-- the attacker's text. workflow-engine/integration-rbac.sql states the rule
-- this broke, in those words: every SECURITY DEFINER function reachable by an
-- end user must do its own authorization check.
-- ---------------------------------------------------------------------
do $$
declare
    a uuid; b uuid; v_res uuid; v_msg1 text; v_msg2 text; v_n int;
begin
    select org_a, org_b, res_a into a, b, v_res from t_ctx;

    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('orgs', array[b])::text, true);

    -- the read side was always right, and is asserted so the write assertions
    -- below cannot be satisfied by the caller simply seeing nothing
    if exists (select 1 from content.resources where id = v_res) then
        raise exception 'org B can see org A''s resource row';
    end if;
    if (select count(*) from content.resolve_file(v_res)) <> 0 then
        raise exception 'org B can resolve org A''s file location';
    end if;

    begin
        perform content.record_chunks(v_res, '[{"content":"REPLACED BY ORG B"}]'::jsonb);
        raise exception 'org B rewrote org A''s chunks';
    exception when insufficient_privilege then raise;
    when others then
        v_msg1 := sqlerrm;
        if v_msg1 like '%rewrote%' then raise; end if;
    end;

    -- and a resource that does not exist must answer identically, or the
    -- refusal becomes an existence oracle over uuids the caller may not hold
    begin
        perform content.record_chunks(gen_random_uuid(), '[{"content":"x"}]'::jsonb);
        raise exception 'chunks were recorded against a resource that does not exist';
    exception when insufficient_privilege then raise;
    when others then
        v_msg2 := sqlerrm;
        if v_msg2 like '%were recorded%' then raise; end if;
    end;
    if v_msg1 is distinct from v_msg2 then
        raise exception
            '"not yours" and "no such thing" answer differently: % vs %', v_msg1, v_msg2;
    end if;

    begin
        perform content.register_upload('t-uploads','t-plant','b','k/p',1,null,'planted',null,a);
        raise exception 'org B planted a resource in org A''s org';
    exception when insufficient_privilege then raise;
    when others then
        if sqlerrm like '%planted a resource%' then raise; end if;
    end;
    begin
        perform content.register_fetched('t-feed','t-plant-2','planted',null,a);
        raise exception 'org B registered a fetched item into org A''s org';
    exception when insufficient_privilege then raise;
    when others then
        if sqlerrm like '%registered a fetched%' then raise; end if;
    end;

    -- org B writing its OWN org is unaffected -- a check that refuses everyone
    -- is not a check, it is an outage
    perform content.register_upload('t-uploads','t-mine','b','k/m',1,null,'mine',null,b);

    reset role;

    select count(*) into v_n from content.resource_chunks where resource_id = v_res;
    if v_n <> 2 or exists (select 1 from content.resource_chunks
                            where resource_id = v_res and content like '%REPLACED%') then
        raise exception 'org A''s chunks were altered: % row(s)', v_n;
    end if;

    raise notice 'content/01: a tenant cannot rewrite, plant into, or probe for another tenant''s content -- and can still write its own';
end $$;

-- ---------------------------------------------------------------------
-- 6. The predicate is in two places, so it is asserted in two places.
--
-- resolve_file() carries the org check as SQL because content.files is granted
-- to nobody and no RLS policy could scope it; the same rule lives on
-- content.resources as a policy. The schema says that duplication is the cost
-- of the design. A test is what keeps a cost from becoming a divergence.
-- ---------------------------------------------------------------------
do $$
declare v_policy text; v_fn text;
begin
    select pg_get_expr(polqual, polrelid) into v_policy
      from pg_policy p join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'content' and c.relname = 'resources' and polname = 'resources_org_scoped';
    select prosrc into v_fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'content' and p.proname = 'resolve_file';

    if v_policy is null or v_fn is null then
        raise exception 'the resources policy or resolve_file is missing';
    end if;
    if position('current_org_ids' in v_policy) = 0
       or position('may_access_org' in v_fn) = 0 then
        raise exception
            'the read predicate and the policy no longer agree about org scoping -- '
            'policy: %', v_policy;
    end if;
    -- and the read path and the write path share ONE predicate, so a service
    -- connection cannot end up able to write what it cannot read
    if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='content' and p.proname='record_chunks') not like '%may_access_org%' then
        raise exception 'record_chunks no longer uses the shared access predicate';
    end if;
    raise notice 'content/01: the read path, the write path and the policy all scope on the same claim';
end $$;

-- ---------------------------------------------------------------------
-- THE ORG EVERYONE READS IS THE ONE A TENANT MAY NOT WRITE.
--
-- The block above asserts that org B cannot plant into org A. It says nothing
-- about the org that is neither, and that was the hole: `may_access_org` let
-- ANY caller write a null org, on the reasoning that a null org "is readable
-- by everyone ... so writing it is not a cross-tenant act". `resources_org_scoped`
-- is `org_id is null or org_id in (...)`, so a null org is not unscoped -- it
-- is scoped to EVERY tenant, and writing one is the widest cross-tenant act
-- available, not the absence of one.
--
-- It took no missing check and no guessed argument to reach: `p_org_id`
-- DEFAULTS to null and the extension ships three null-org channels. An
-- ordinary authenticated user of one org, holding nothing, planted a document
-- that another org's TEXT search over the shipped `chunks` corpus returned.
-- That is §4a's own threat sentence reached through a default value.
--
-- All four callers are asserted, because the fix is a discrimination and the
-- risk of getting it wrong is refusing the deployment rather than the attacker.
-- ---------------------------------------------------------------------
do $$
declare
    v_a uuid := gen_random_uuid();
    v_b uuid := gen_random_uuid();
    v_u uuid;
    v_res uuid;
    v_planted boolean := false;
begin
    insert into rbac.users (email, status)
    values ('tenancy-probe@example.com', 'active') returning id into v_u;

    -- 1. A TENANT MAY NOT WRITE THE NULL ORG. The attack, as an ordinary user
    --    with a valid token, against the channel the extension itself ships.
    set local role authenticated;
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_u, 'orgs', array[v_b])::text, true);
    begin
        v_res := content.register_upload('uploads', 't-null-1', 'bucket', 'k-null-1',
                                         42, 'text/markdown', 'planted');
        v_planted := true;
    exception when others then
        null;
    end;
    reset role;
    if v_planted then
        raise exception
            'a tenant wrote a resource with org_id NULL, which resources_org_scoped '
            'makes readable by EVERY other tenant -- content injection into every '
            'corpus in the deployment, through an argument they did not even pass';
    end if;

    -- 2. THE SINGLE-TENANT DEPLOYMENT STILL WORKS. A token that names no org
    --    is not a tenant, and for it a null org means "ours".
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);
    v_res := content.register_upload('uploads', 't-null-2', 'bucket', 'k-null-2',
                                     42, 'text/markdown', 'single tenant');
    reset role;
    if v_res is null then
        raise exception 'a token carrying no org claim can no longer write the shared org';
    end if;

    -- 3. A SERVICE CONNECTION STILL WORKS -- no claims at all: a migration,
    --    psql, the ingest worker. This is the exemption the function is built
    --    around and the one most easily broken by tightening the others.
    v_res := content.register_upload('uploads', 't-null-3', 'bucket', 'k-null-3',
                                     42, 'text/markdown', 'service');
    if v_res is null then
        raise exception 'a claimless service connection can no longer register content';
    end if;

    -- 4. AND A TENANT STILL WRITES ITS OWN ORG.
    insert into content.channels (name, kind, org_id) values ('tenancy-probe-b', 'file_upload', v_b);
    set local role authenticated;
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_u, 'orgs', array[v_b])::text, true);
    v_res := content.register_upload('tenancy-probe-b', 't-own-1', 'bucket', 'k-own-1',
                                     42, 'text/markdown', 'own', null, v_b);
    reset role;
    if v_res is null then
        raise exception 'the tightened check refuses a tenant writing its own org';
    end if;

    -- And org A, the bystander, sees none of it.
    if exists (select 1 from content.resources where org_id is null and title = 'planted') then
        raise exception 'the planted resource exists despite the write being refused';
    end if;
    perform v_a;

    raise notice 'content/01: a tenant cannot write the null org that every tenant reads, and the single-tenant, service and own-org paths are untouched';
end $$;

rollback;
