-- THE CONTENT PLANE, EXECUTED -- and the tenancy hole that found.
--
-- `world-model-ingestion` is marked **Built** and had no test directory at
-- all. Every capability it declares was present in surface.sql and unexercised
-- by anything, which is how the defect in §5 survived: the READ path was
-- scoped correctly the whole time, so every question anyone had asked -- can
-- this tenant see that? -- got the right answer.
--
-- Nobody had asked what a tenant could WRITE.

-- WHAT THIS FILE NEEDS FROM THE `rbac` SURFACE, named because the next person
-- to run it alone will otherwise read the failure as their own regression.
--
-- §1 registers an upload as alice ('1111...'), and content.register_upload gates
-- on content.may_upload, which needs `resources:create`. Alice holds it through
-- a role that the `rbac` surface seeds, not through anything in this file. So:
--
--     dev/tests/run.sh content      -> §1 fails, "not authorized to upload content"
--     dev/tests/run.sh              -> green, because rbac runs first
--
-- run.sh's SURFACES order is deliberate and documented in its own header
-- ("RBAC first, because if row-level security is not actually on, every later
-- assertion about who-sees-what is meaningless"), so this is a dependency to
-- state rather than a bug to fix here. Measured while fixing REM-73, where it
-- cost a few minutes of reading a correct diff for a fault that was not in it.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- Two tenants, two channels, and a caller identity that is a request-scoped
-- claim rather than a role -- which is what the deployment actually does:
-- PostgREST connects as one login role and sets the verified JWT per request.
create temp table t_ctx (org_a uuid, org_b uuid, res_a uuid);
insert into t_ctx values (gen_random_uuid(), gen_random_uuid(), null);

-- THE ORGS ARE ROWS NOW, so a fixture cannot invent a uuid and call it a
-- tenant. content.channels.org_id references rbac.orgs, which is the point --
-- an org_id naming no org used to produce rows nobody could see and nothing
-- could report. The two users exist for the same reason: membership is what
-- rbac.current_org_ids() reads, so a claim naming an org with no member behind
-- it is an anonymous caller, correctly.
do $$
declare a uuid; b uuid;
begin
    select org_a, org_b into a, b from t_ctx;
    insert into rbac.orgs (id, slug, name) values
        (a, 't-org-a-' || left(a::text, 8), 'Test Org A'),
        (b, 't-org-b-' || left(b::text, 8), 'Test Org B');
    insert into rbac.org_members (org_id, user_id) values
        (a, '11111111-1111-1111-1111-111111111111'),
        (b, '22222222-2222-2222-2222-222222222222')
    on conflict do nothing;
end $$;

do $$
declare a uuid; b uuid;
begin
    select org_a, org_b into a, b from t_ctx;
    -- `org`, because these are per-org channels and the default is not.
    -- content.channels.visibility defaults to 'private' and owner_id has no
    -- default, so a raw insert makes a channel owned by nobody that private
    -- means nobody may read: rbac.may_read(null, org, 'private') is NULL, the
    -- lookup in register_upload drops the row, and the caller is told "no
    -- channel named t-uploads for this org" about a channel that is right
    -- there. content.save_source, the supported path, sets owner_id instead;
    -- this file writes the rows directly and has to say which it means.
    insert into content.channels (name, kind, org_id, visibility) values ('t-uploads', 'file_upload', a, 'org');
    insert into content.channels (name, kind, org_id, visibility) values ('t-uploads', 'file_upload', b, 'org');
    insert into content.channels (name, kind, org_id, visibility) values ('t-feed', 'feed', a, 'org');
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

    -- A CALLER IDENTITY, because a real upload has one. This block used to run
    -- with no claims at all, so register_upload stamped owner_id = null (there
    -- is no current user) and visibility = 'private' -- a resource owned by
    -- nobody that nobody may read, which is the correct answer to a question
    -- the fixture did not mean to ask.
    --
    -- It went unnoticed while resolve_file() gated on the ORG alone: a null
    -- owner is invisible to a rule that never looks at the owner. Tightening
    -- that gate to rbac.may_read(owner, org, visibility) made the fixture's
    -- own unreality fail, which is the test doing its job on itself. The file
    -- header already said the deployment sets a JWT per request; this block
    -- was the one place that did not.
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text, ''));

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

-- The same bytes uploaded twice into one org are two DOCUMENTS, and both must
-- become answerable. The Content Server derives the object key from the
-- checksum, so both resources carry the same `uri` -- and the document node's
-- canonical key was `coalesce(uri, external_id, id)`, so the second one to
-- reach `ready` died in the projection trigger on idx_node_keys_canonical and
-- its ingest run failed terminally. Found by our end-to-end tour re-uploading its
-- runbook. The bytes' address is the file's identity, not the document's.
do $$
declare a uuid; v_1 uuid; v_2 uuid;
begin
    select org_a into a from t_ctx;
    v_1 := content.register_upload('t-uploads','t-same','p8-content','objects/aa/t-same',10,'text/plain','copy one','s3://p8-content/objects/aa/t-same',a);
    v_2 := content.register_upload('t-uploads','t-same','p8-content','objects/aa/t-same',10,'text/plain','copy two','s3://p8-content/objects/aa/t-same',a);
    if v_1 = v_2 then raise exception 'two uploads with no external_id collapsed into one resource'; end if;
    perform content.record_chunks(v_1, '[{"content":"identical bytes, first upload"}]'::jsonb);
    perform content.record_chunks(v_2, '[{"content":"identical bytes, second upload"}]'::jsonb);
    if (select count(*) from aiq.nodes where entity_type = 'document' and entity_id in (v_1, v_2)) <> 2 then
        raise exception 'the same bytes uploaded twice did not yield two document nodes';
    end if;
    raise notice 'content/01: the same bytes uploaded twice are two documents, both answerable';
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
    -- `public`, for the reason the fixture at the top of this file already
    -- gives and this line did not take: omitted, the columns default to
    -- private with no owner, which content.channels now refuses outright
    -- (REM-83). What this block measures is a BROKEN ingest_workflow, so the
    -- channel only has to be resolvable.
    insert into content.channels (name, kind, org_id, config, visibility)
    values ('t-broken','file_upload', a, '{"ingest_workflow":"no_such_workflow"}'::jsonb, 'public');
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
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', '22222222-2222-2222-2222-222222222222', 'orgs', array[b])::text, ''));

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

    -- THE MESSAGE, NOT THE SQLSTATE, is what tells the designed refusal from a
    -- bare permission denial here: REM-67 gave assert_org_write's raise
    -- errcode 42501, which is also what a missing GRANT raises, so the arm
    -- above (`when insufficient_privilege then raise`) would now pass a table
    -- privilege off as the tenancy check working.
    begin
        perform content.register_upload('t-uploads','t-plant','b','k/p',1,null,'planted',null,a);
        raise exception 'org B planted a resource in org A''s org';
    exception when others then
        if sqlerrm not like 'not authorized to % for that organization' then raise; end if;
    end;
    begin
        perform content.register_fetched('t-feed','t-plant-2','planted',null,a);
        raise exception 'org B registered a fetched item into org A''s org';
    exception when others then
        if sqlerrm not like 'not authorized to % for that organization' then raise; end if;
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
-- 6. The predicate is in two places, so it is asserted in two places --
--    BY BEHAVIOUR, because asserting it by source text asserted nothing.
--
-- resolve_file() carries the read check as SQL because content.files is granted
-- to nobody and no RLS policy could scope it; the same rule lives on
-- content.resources as a policy. The schema says that duplication is the cost
-- of the design. A test is what keeps a cost from becoming a divergence.
--
-- WHAT THIS BLOCK USED TO DO, AND WHY IT CAUGHT NOTHING (REM-73). It greped
-- prosrc:
--
--     if position('may_access_org' in v_fn) = 0 then
--         raise exception 'resolve_file no longer applies the org check';
--
-- resolve_file does not call may_access_org and has not for some time. It
-- calls rbac.may_read, deliberately, and its body carries the sentence
-- "may_read, NOT may_access_org" explaining the choice. That comment was the
-- only occurrence of the string in the body, so the assertion passed BECAUSE
-- of a sentence saying the thing it greped for is not used -- and would have
-- gone on passing if the predicate were deleted and the comment kept.
--
-- THE SAME WAS TRUE OF THE record_chunks ARM, which REM-73 recorded as still
-- live. It is not, and the sibling sweep the postmortem's §6 rule asks for is
-- what found it: record_chunks moved to rbac.may_write and kept a comment
-- reading "This asked rbac.may_access_org(org), which answers...". Verified on
-- a live 0.2.0 install -- for both functions the one occurrence of the string
-- is inside a comment saying it is not what the function calls. Two arms, one
-- defect, and the ticket had spotted one of them.
--
-- So both arms are now behavioural, and the subject is chosen so the specific
-- regression the greps pretended to guard -- may_read weakening back to
-- may_access_org -- is the thing that makes them fail. A caller who is a
-- MEMBER OF THE OWNER'S ORG but may not read the row passes may_access_org and
-- fails may_read: that is the only caller who tells the two predicates apart,
-- and neither the org-B caller of §5 nor the owner of §1 is one.
--
-- Our postmortems call the class "a check that cannot distinguish
-- pass from fail". dev/assertion-audit.py catches one spelling of it (a scalar
-- subquery going three-valued); a grep for a name that appears in a comment is
-- another, and no tool catches that one -- only asking what the code DOES.
--
-- THE POLICY HALF IS NOW ASSERTED AGAINST ITS GENERATOR rather than against a
-- substring. It used to check `position('current_org_ids' in v_policy) <> 0`,
-- which passes for any policy that mentions the function -- including one
-- somebody rewrote by hand into something weaker that still calls it. The
-- predicate has one home, rbac.scope_predicate(), and every scoped policy in
-- the collection is generated from it, so the honest question is whether this
-- table's live policy is still that text. Asking the generator rather than
-- restating its output is the same rule dev/vocab-audit.py follows against
-- p8.enums(): an audit that keeps its own copy is one more copy free to drift.
-- ---------------------------------------------------------------------
do $$
declare v_policy text; v_fn text;
begin
    select pg_get_expr(polqual, polrelid) into v_policy
      from pg_policy p join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'content' and c.relname = 'resources' and polname = 'resources_scoped';
    select prosrc into v_fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'content' and p.proname = 'resolve_file';

    if v_policy is null or v_fn is null then
        raise exception 'the resources policy or resolve_file is missing';
    end if;

    -- The three things the predicate must consult. A string comparison against
    -- scope_predicate() itself is not available here: pg_get_expr returns the
    -- PARSED form -- casts made explicit, whitespace regularised -- while the
    -- generator returns source text, so the two never match literally.
    -- dev/tests/rbac/02 does the exact comparison, by generating a throwaway
    -- table's policy in the same database and diffing the two parsed forms;
    -- this file asserts the weaker property, that all three axes are present,
    -- which is what content specifically cares about.
    --
    -- WHAT THIS GREP CAN AND CANNOT CATCH, recorded because the two arms
    -- that used to follow it were greps that caught nothing (REM-73, and the
    -- block header above).
    --
    -- It CAN catch: an axis dropped outright -- a policy hand-rewritten to
    -- consult the org and the owner but not the visibility, which is a shape
    -- somebody reaching for "make it work" produces.
    --
    -- It CANNOT catch: a policy that mentions all three names and still decides
    -- wrongly -- `or true`, an inverted test, an axis consulted in a branch that
    -- never runs. It also cannot catch a name that appears only in a COMMENT,
    -- which is the exact way the two arms below it passed for months. It is safe
    -- from that particular failure only because pg_get_expr returns a parsed
    -- expression with no comments in it, not because a grep is a good idea.
    --
    -- It is kept rather than deleted because it is cheap and names the axes for
    -- a reader; the assertion that decides this section is the block that follows,
    -- and rbac/02 holds the exact-text comparison. A green result here on its
    -- own would not be evidence that the policy is right.
    if position('rbac.current_org_ids' in v_policy) = 0
       or position('rbac.current_user_id' in v_policy) = 0
       or position('visibility' in v_policy) = 0 then
        raise exception
            'the resources policy is no longer the generated scope predicate -- '
            'it must consult the owner, the org AND the visibility. policy: %',
            v_policy;
    end if;
    raise notice 'content/01: the resources policy still consults the owner, the org and the visibility';
end $$;

-- THE BEHAVIOURAL HALF -- a caller who tells may_read and may_access_org apart.
--
-- The subject is a PRIVATE resource in org A, and the caller is a SECOND MEMBER
-- of org A. For that pair:
--
--   rbac.may_access_org(org_a)                  -> true   (they are a member)
--   rbac.may_read(alice, org_a, 'private')      -> false  (not theirs)
--
-- so a resolve_file that asks the org returns the storage keys and one that
-- asks the row returns nothing. Nothing else in this file distinguishes them:
-- §1's caller owns the row and §5's caller is in a different org, which is why
-- the org-vs-row regression needed a grep to stand in for it and got one that
-- did not work.
--
-- res_a is not reusable as the subject: register_upload named an org, so
-- rbac.default_visibility() made it 'org', and an org-visible row is one every
-- member may read. The subject has to be `private`, passed explicitly.
do $$
declare
    a uuid; v_alice uuid := '11111111-1111-1111-1111-111111111111';
    v_carol uuid := '33333333-3333-3333-3333-333333333333';
    v_priv uuid; v_sees_row boolean; v_resolves boolean; v_n int;
begin
    select org_a into a from t_ctx;

    -- a second member of org A, and the private row alice owns there
    insert into rbac.users (id, email, status)
        values (v_carol, 't-carol-' || left(a::text, 8) || '@example.test', 'active')
        on conflict (id) do nothing;
    insert into rbac.org_members (org_id, user_id) values (a, v_carol)
        on conflict do nothing;

    set local role authenticated;
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_alice, 'orgs', array[a])::text);
    v_priv := content.register_upload('t-uploads', 't-sum-priv', 'bucket', 'keys/priv',
                                      64, 'text/plain', 'Alice private', null, a,
                                      '{}'::jsonb, null, null, 'private');
    if v_priv is null then
        raise exception 'the private subject was not registered';
    end if;
    -- it has bytes, so resolve_file has something to return and a green result
    -- below cannot mean "there was never a row to find"
    if (select count(*) from content.resolve_file(v_priv)) <> 1 then
        raise exception
            'its own owner cannot resolve the private subject -- the assertions '
            'below would pass on an empty subject rather than on the predicate';
    end if;

    -- NOW AS CAROL: in the org, not the owner, and the row is private.
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_carol, 'orgs', array[a])::text);

    -- the premise, measured rather than assumed: carol is exactly the caller
    -- who separates the two predicates
    if rbac.may_access_org(a) is distinct from true then
        raise exception
            'carol cannot act in org A, so she does not distinguish may_read '
            'from may_access_org and this block measures nothing';
    end if;

    v_sees_row  := exists (select 1 from content.resources where id = v_priv);
    v_resolves  := exists (select 1 from content.resolve_file(v_priv));

    -- (a) resolve_file asks the ROW. This is REM-73's first bullet: a resource
    --     a second caller may not read returns no row, run as that caller with
    --     their own claims.
    if v_resolves then
        raise exception
            'resolve_file returned storage keys for a private resource to a '
            'co-member of its org -- it is asking the ORG, not the row, so a '
            'caller can resolve keys for a resource they cannot read';
    end if;

    -- (b) and the POLICY agrees with it, which is what "the predicate is in two
    --     places" means. Asserted as a biconditional so a drift in EITHER copy
    --     fires: the table read is RLS-scoped, resolve_file is SECURITY DEFINER
    --     and scopes itself, and the two must answer the same question.
    if v_sees_row is distinct from v_resolves then
        raise exception
            'the policy and resolve_file disagree about the same row for the '
            'same caller: the table read says %, resolve_file says % -- the '
            'duplicated predicate has drifted', v_sees_row, v_resolves;
    end if;

    -- (c) record_chunks asks the row's WRITE rule, replacing the second inert
    --     grep. Carol may act in org A, so a function asking may_access_org
    --     would let her replace the chunks of a row she cannot even read.
    --     §5 asserts this for a caller in another org; this asserts it for the
    --     caller who passes the org check, which is the one that mattered.
    begin
        perform content.record_chunks(v_priv, '[{"content":"REPLACED BY CAROL"}]'::jsonb);
        raise exception
            'a co-member of the org rewrote the chunks of a private resource '
            'she cannot read -- record_chunks is asking the org, not the row';
    exception when others then
        if sqlerrm like 'a co-member%' then raise; end if;
    end;

    reset role;

    -- and nothing was actually written, checked outside the caller's own RLS
    select count(*) into v_n from content.resource_chunks
     where resource_id = v_priv and content like '%REPLACED BY CAROL%';
    if v_n <> 0 then
        raise exception 'carol''s chunks landed after all: % row(s)', v_n;
    end if;

    raise notice 'content/01: the read path, the write path and the policy all refuse a co-member who may not read the row -- asked as behaviour, not as a substring';
end $$;

-- ---------------------------------------------------------------------
-- THE ORG EVERYONE READS IS THE ONE A TENANT MAY NOT WRITE.
--
-- The block above asserts that org B cannot plant into org A. It says nothing
-- about the org that is NEITHER, and that was the hole. `may_access_org` let
-- any caller write a null org, on the reasoning that a null org "is readable
-- by everyone ... so writing it is not a cross-tenant act". The policy was
-- `org_id is null or org_id in (...)`, so a null org was not unscoped -- it was
-- scoped to EVERY tenant, and writing one was the widest cross-tenant act
-- available, not the absence of one. (That predicate is spelled `org_id =
-- rbac.shared_org_id() or org_id in (...)` today, and the shared tier is a row
-- rather than a NULL -- which changes nothing about this argument and
-- everything about whether a reader can see it being made.) It took no missing check and no guessed
-- argument to reach: `p_org_id` DEFAULTS to null and the extension ships three
-- null-org channels, so an ordinary user of one org planted a document that
-- another org's TEXT search over the shipped corpus returned.
--
-- THE GUARANTEE THIS FILE ASSERTS HAS CHANGED, and it is now the stronger one.
-- The old fix REFUSED the write, because a written row would have been
-- readable by everyone. Scope removes that premise: a resource carries
-- `visibility`, an omitted org means the row is the uploader's own, and being
-- readable by everyone is `public` -- a value somebody types. So the write is
-- allowed and the disclosure is not, which is a better answer than refusing a
-- legitimate upload. What must hold, and is asserted below:
--
--   1. a tenant CAN register without naming an org...
--   2. ...and no other tenant can read what they wrote
--   3. the single-tenant deployment is untouched
--   4. a claimless service connection is untouched
--   5. a tenant still writes its own org, and it is org-visible there
-- ---------------------------------------------------------------------
do $$
declare
    v_a uuid := gen_random_uuid();
    v_b uuid := gen_random_uuid();
    v_u uuid;
    v_res uuid;
    v_vis text;
    v_org uuid;
begin
    insert into rbac.orgs (id, slug, name) values
        (v_a, 'probe-a-' || left(v_a::text, 8), 'Probe A'),
        (v_b, 'probe-b-' || left(v_b::text, 8), 'Probe B');
    insert into rbac.users (email, status)
    values ('tenancy-probe@example.com', 'active') returning id into v_u;
    -- MEMBERSHIP, not just a claim. This is the change the whole suite turns
    -- on: rbac.current_org_ids() reads rbac.org_members and intersects the
    -- token's claim with it, so a token naming an org the user does not belong
    -- to is not that org's caller. Before, the array in the token WAS the
    -- membership, and this probe would have passed while asserting nothing.
    insert into rbac.org_members (org_id, user_id) values (v_b, v_u);
    -- A ROLE, because membership is not permission. This probe is about
    -- tenancy -- whose org a row lands in and who can read it back -- and it
    -- registers content to get something to test with. `resources:create`
    -- (0.1.10) made registering a permission, so a user with no role now fails
    -- at content.may_upload before reaching anything this block asserts. An
    -- ordinary member is what this user is meant to be.
    insert into rbac.user_roles (user_id, role) values (v_u, 'member')
    on conflict do nothing;

    -- 1. A TENANT REGISTERS WITHOUT NAMING AN ORG. Allowed now -- the act the
    --    old rule refused -- because the row it produces is private.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', v_u, 'orgs', array[v_b])::text, ''));
    v_res := content.register_upload('uploads', 't-null-1', 'bucket', 'k-null-1',
                                     42, 'text/markdown', 'planted');
    reset role;
    if v_res is null then
        raise exception 'a tenant can no longer register content without naming an org';
    end if;

    -- 2. ...AND IT IS NOT READABLE BY ANYBODY ELSE. This is the assertion that
    --    replaces "the write is refused", and it is the one that actually
    --    matters: the old failure was a READ by another tenant, and refusing
    --    the write was one way to prevent it rather than the guarantee itself.
    --
    -- `org_id = rbac.shared_org_id()` and not `org_id is null`: org_id is NOT
    -- NULL now (specs/identity/spec.md §4), so an upload that named no org
    -- lands on the shared TIER rather than carrying no tier at all. The
    -- assertion below is deliberately unchanged in what it means -- the row
    -- must not be scoped to any tenant, and `private` is what keeps it out of
    -- everyone's reach. Being on the shared org buys the row nothing; only
    -- `visibility` does, and the read probe two statements down is what
    -- actually proves it.
    select visibility, org_id into v_vis, v_org
      from content.resources where id = v_res;
    if v_vis is distinct from 'private' or v_org is distinct from rbac.shared_org_id() then
        raise exception
            'a resource registered with no org came out as (%, %), not a private '
            'row on the shared tier owned by its uploader -- which is what stops '
            'another tenant reading it', v_vis, v_org;
    end if;
    -- and prove it by reading, as org A, rather than by trusting the column
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text, ''));
    if exists (select 1 from content.resources where id = v_res) then
        reset role;
        raise exception
            'another tenant can read a resource registered with no org -- this is '
            'the cross-tenant read the null-org tier used to produce, arrived at '
            'through the scope column instead';
    end if;
    reset role;

    -- 3. THE SINGLE-TENANT DEPLOYMENT STILL WORKS. A token that names no org
    --    is not a tenant, and its uploads are simply its own.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', v_u)::text, ''));
    v_res := content.register_upload('uploads', 't-null-2', 'bucket', 'k-null-2',
                                     42, 'text/markdown', 'single tenant');
    reset role;
    if v_res is null then
        raise exception 'a token carrying no org claim can no longer register content';
    end if;

    -- 4. A SERVICE CONNECTION STILL WORKS -- no claims at all: a migration,
    --    psql, the ingest worker. This is the exemption the rule is built
    --    around and the one most easily broken by tightening the others. It
    --    lands `public`, because a connection with no request identity is an
    --    operator installing deployment content (rbac.default_visibility).
    --
    --    THE CLAIMS ARE CLEARED EXPLICITLY, and they were not: `reset role`
    --    puts back the Postgres role and does nothing to request.jwt.claims,
    --    which set_config(..., true) leaves set for the rest of the
    --    transaction. So every "service connection" case in this file was
    --    running as whoever the previous case impersonated, and the assertion
    --    passed for the wrong reason -- it only checked that the call
    --    succeeded, which it does either way. Caught by asserting the
    --    visibility as well: the row came back `private`, which is the answer
    --    for a logged-in caller and not for a migration.
    execute format('set local request.jwt.claims = %L', '');
    v_res := content.register_upload('uploads', 't-null-3', 'bucket', 'k-null-3',
                                     42, 'text/markdown', 'service');
    if v_res is null then
        raise exception 'a claimless service connection can no longer register content';
    end if;
    if (select visibility from content.resources where id = v_res) is distinct from 'public' then
        raise exception
            'a service connection registered content as %, not public -- the '
            'operator-installs-configuration arm of rbac.default_visibility',
            (select visibility from content.resources where id = v_res);
    end if;

    -- 5. AND A TENANT STILL WRITES ITS OWN ORG, org-visible there.
    insert into content.channels (name, kind, org_id, visibility)
    values ('tenancy-probe-b', 'file_upload', v_b, 'org');
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', v_u, 'orgs', array[v_b])::text, ''));
    v_res := content.register_upload('tenancy-probe-b', 't-own-1', 'bucket', 'k-own-1',
                                     42, 'text/markdown', 'own', null, v_b);
    reset role;
    if v_res is null then
        raise exception 'a tenant can no longer register into its own org';
    end if;
    if (select visibility from content.resources where id = v_res) is distinct from 'org' then
        raise exception 'a resource registered into an org did not come out org-scoped';
    end if;

    perform v_a;

    raise notice 'content/01: registering without an org is allowed and private, no other tenant can read it, and the single-tenant, service and own-org paths are untouched';
end $$;

rollback;
