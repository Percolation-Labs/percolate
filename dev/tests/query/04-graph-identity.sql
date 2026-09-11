-- GRAPH SURFACE, part 1 -- identity: the registry, the keys, and the
-- projection that keeps them true.
--
-- `graph-identity.md` ends with a "Verification (principle-level)" section
-- that opens "A design is correct if all of these hold" and lists eight
-- criteria. Nothing executed them. This file and `05-graph-traversal.sql`
-- do; each assertion below names the criterion or the invariant it holds up.
--
-- The characteristic failure of this half is a registry that has quietly
-- stopped describing the tables it projects: a node whose source row no
-- longer qualifies, a name that outlived its rename, a second row that took a
-- key that was supposed to be unique. None of those raise anything. Every one
-- of them was found here by running it, and every assertion below fails again
-- if the fix is removed.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

-- A throwaway typed table rather than the committed sample in
-- `dev/init/04-graph-sample.sql`: this half is about the WRITE path, and the
-- write path has to be exercised with writes. The sample is what
-- `05-graph-traversal.sql` reads. Registering brings its own triggers, so the
-- fixture is complete inside this transaction and gone after it.
create table demo_t_widget (
    id       uuid primary key default gen_random_uuid(),
    name     text not null,
    listed   boolean not null default true,
    org_id   uuid
);

select aiq.register_entity_table(
    'ttype_widget', 'public.demo_t_widget', 'n.name', 'n.name', 'n.org_id', 'n.listed');

-- ---------------------------------------------------------------------
-- 1. INVARIANT 4: LOOKUP AFTER AN INSERT SEES THE NODE IN THAT TRANSACTION.
--
-- This is the one requirement in the whole design that forces a synchronous
-- write path (D10: everything else derived is a workflow-engine task, this is
-- not, and the reason is exactly this line). A queue-based projection would
-- pass every other assertion in this file and fail this one.
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
    insert into demo_t_widget (name) values ('Widget One') returning id into v_id;

    if not exists (select 1 from aiq.lookup('Widget One')) then
        raise exception 'LOOKUP does not see a node projected in this same '
                        'transaction -- invariant 4, the one requirement that '
                        'rules out an async projection';
    end if;
    -- ...and the identity resolves back to the typed row by PK, which is the
    -- other half: the registry stores identity, never the payload.
    if (select w.name from aiq.lookup('Widget One') l
         join demo_t_widget w on w.id = l.entity_id) is distinct from 'Widget One' then
        raise exception 'the node does not hydrate back to its typed row';
    end if;
    raise notice 'query/04: a node is LOOKUP-able in the transaction that made it';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE INCLUSION PREDICATE IS ENFORCED IN BOTH DIRECTIONS.
--
-- Invariant 3: every `nodes` row satisfies the inclusion predicate. Insert
-- was always checked. UPDATE was not, and that is the interesting half:
--
--   update demo_t_widget set listed = false where ...
--
-- left the node, its key and its edges exactly where they were. A row
-- withdrawn from the graph stayed LOOKUP-able and stayed an edge endpoint,
-- and `check_drift` -- the function whose whole job is to find a writer bug --
-- dutifully reported the node the projection had just failed to clean up.
--
-- The projection's UPDATE path now evicts as well as inserts, which is what
-- makes rebuild and live projection agree (they share the predicate, and now
-- they share both directions of it).
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
    insert into demo_t_widget (name, listed) values ('Excluded Widget', false)
    returning id into v_id;
    if exists (select 1 from aiq.nodes where entity_type='ttype_widget' and entity_id=v_id) then
        raise exception 'an excluded row was projected on INSERT';
    end if;

    -- false -> true: it joins the graph
    update demo_t_widget set listed = true where id = v_id;
    if not exists (select 1 from aiq.nodes where entity_type='ttype_widget' and entity_id=v_id) then
        raise exception 'a row that became included was not projected on UPDATE';
    end if;

    -- true -> false: it must LEAVE the graph
    update demo_t_widget set listed = false where id = v_id;
    if exists (select 1 from aiq.nodes where entity_type='ttype_widget' and entity_id=v_id) then
        raise exception
            'a row that stopped satisfying the inclusion predicate kept its node. '
            'It is still LOOKUP-able and can still be an edge endpoint -- '
            'invariant 3, broken by the projection itself';
    end if;
    if exists (select 1 from aiq.node_keys where key = 'excluded widget') then
        raise exception 'the evicted node kept its key';
    end if;

    -- ...and the drift check agrees, which is the point of having both: the
    -- detector must be quiet when the writer is correct, or nobody will
    -- believe it when it is not.
    if exists (select 1 from aiq.check_drift('ttype_widget')) then
        raise exception 'check_drift reports drift after a correct projection: %',
            (select string_agg(direction || ' ' || entity_id, ', ')
               from aiq.check_drift('ttype_widget'));
    end if;
    raise notice 'query/04: inclusion is enforced on UPDATE in both directions';
end $$;

-- ---------------------------------------------------------------------
-- 3. A RENAME REPLACES THE CANONICAL KEY. IT DOES NOT ADD ONE.
--
-- graph-identity.md's verification list says "Rename a node; keys change;
-- existing edges still attach (ids did not change)". Keys did not change --
-- they accumulated. After renaming, the node answered to BOTH names forever,
-- and the canonical-key unique index could not catch it because that index
-- scopes uniqueness ACROSS nodes, not within one.
--
-- The second half is worse than the stale name and is asserted below: the
-- ghost key sits in the unique index, so the next row that legitimately takes
-- the old name collides with a key belonging to a node nobody can see is
-- involved.
--
-- Short keys and aliases are deliberately NOT swept: they are editorial, and
-- a rename is not a reason to forget a synonym somebody taught the graph.
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
    insert into demo_t_widget (name) values ('Old Name') returning id into v_id;
    perform aiq.add_node_key('Old Name', 'oldie', 'short');

    update demo_t_widget set name = 'New Name' where id = v_id;

    if exists (select 1 from aiq.lookup('Old Name')) then
        raise exception
            'the pre-rename name still resolves -- the node now has two '
            'canonical keys, each claiming to be the one derived from key_expr';
    end if;
    if not exists (select 1 from aiq.lookup('New Name')) then
        raise exception 'the renamed node does not answer to its new name';
    end if;
    if not exists (select 1 from aiq.lookup('oldie')) then
        raise exception 'a rename swept away a short key, which is editorial '
                        'and was never derived from the name that changed';
    end if;

    -- The ghost-key consequence: the freed name must be takeable.
    insert into demo_t_widget (name) values ('Old Name');
    if (select count(*) from aiq.lookup('Old Name')) <> 1 then
        raise exception 'the freed name did not come back cleanly';
    end if;
    raise notice 'query/04: a rename moves the canonical key and frees the old one';
end $$;

-- ---------------------------------------------------------------------
-- 4. A CANONICAL KEY IS UNIQUE PER (ORG, TYPE) -- INCLUDING THE SHARED TIER.
--
-- The index was `unique (org_id, key, entity_type) where kind = 'canonical'`
-- with Postgres's default NULLS DISTINCT, back when org_id was nullable and a
-- NULL meant shared reference data -- which integration-rbac.sql §1 calls "a
-- real category here, not a loophole" and which every public entity in a
-- deployment will be. Two NULLs never conflict, so the guarantee held for
-- tenants and was absent for exactly the tier that is shared, and LOOKUP,
-- documented as an exact match, returned two different nodes for one canonical
-- key.
--
-- org_id is NOT NULL now and the shared tier is rbac.shared_org_id()
-- (specs/identity/spec.md §4), so the index constrains it by the same equality
-- as every tenant and the NULLS NOT DISTINCT flag is a documented no-op. WHAT
-- THIS BLOCK ASSERTS IS UNCHANGED, and deliberately so: the guarantee was
-- never the flag, it was that one canonical key names one node per tier. If
-- this still passes after the column stopped being nullable, that is evidence
-- the migration preserved the guarantee rather than deleted the case.
--
-- Asserted through the PROJECTION rather than by hand-inserting a key, because
-- that is how the duplicate actually arrived: two source rows whose key_expr
-- produced the same string.
-- ---------------------------------------------------------------------
do $$
declare v_msg text;
begin
    insert into demo_t_widget (name) values ('Contested');
    begin
        insert into demo_t_widget (name) values ('Contested');
        raise exception
            'two shared rows both took the canonical key `contested`. LOOKUP '
            'now returns % nodes for a key the dialect documents as exact',
            (select count(*) from aiq.lookup('Contested'));
    exception when unique_violation then
        null;   -- the projection refused it, which is the whole point
    end;

    -- ...and the same key IS allowed once per tenant, which is why the index
    -- is scoped on org_id at all rather than being unique on (key, type).
    insert into demo_t_widget (name, org_id) values
        ('Contested', 'a0000000-0000-0000-0000-00000000000a'),
        ('Contested', 'a0000000-0000-0000-0000-00000000000b');
    if (select count(*) from aiq.node_keys where key='contested' and kind='canonical') <> 3 then
        raise exception 'two tenants and the shared tier cannot each hold the '
                        'same canonical key, which is what org scoping is for';
    end if;
    raise notice 'query/04: canonical keys are unique per (org, type), nulls included';
end $$;

-- ---------------------------------------------------------------------
-- 5. TWO TABLES WITH THE SAME SHORT NAME MUST NOT SHARE A PROJECTION.
--
-- The generated projection functions were named after the source table's
-- SHORT name -- `split_part(source_table, '.', 2)` -- so registering
-- `s1.thing` and `s2.thing` generated `aiq.project_thing_ins` twice and the
-- second CREATE OR REPLACE silently rewrote the first, with the other type's
-- entity_type baked into its body. Rows written to s1.thing were projected as
-- the OTHER type: identity for a whole table, wrong, with nothing raised.
--
-- Two schemas with a table of the same name is not an exotic shape -- it is
-- what a per-tenant or per-consumer schema layout looks like.
-- ---------------------------------------------------------------------
do $$
begin
    create schema t_s1; create schema t_s2;
    create table t_s1.thing (id uuid primary key default gen_random_uuid(), nm text);
    create table t_s2.thing (id uuid primary key default gen_random_uuid(), nm text);
    perform aiq.register_entity_table('ttype_one', 't_s1.thing', 'n.nm');
    perform aiq.register_entity_table('ttype_two', 't_s2.thing', 'n.nm');

    insert into t_s1.thing (nm) values ('from-schema-one');
    insert into t_s2.thing (nm) values ('from-schema-two');

    if (select entity_type from aiq.lookup('from-schema-one')) is distinct from 'ttype_one' then
        raise exception
            'a row from t_s1.thing was projected as %, not ttype_one -- two '
            'registered tables sharing a short name share a projection function',
            (select entity_type from aiq.lookup('from-schema-one'));
    end if;
    if (select entity_type from aiq.lookup('from-schema-two')) is distinct from 'ttype_two' then
        raise exception 'the second registration lost its own projection';
    end if;
    raise notice 'query/04: projections are keyed by entity type, not table name';
end $$;

-- One table, one entity type. Two types over one table cannot both work --
-- the trigger names are fixed, so the second registration's triggers replace
-- the first's -- and the failure was silent: the FIRST type simply stopped
-- being projected while its registry row went on describing it.
do $$
declare v_msg text;
begin
    begin
        perform aiq.register_entity_table('ttype_shadow', 't_s1.thing', 'n.nm');
        raise exception 'a second entity type was registered over a table that '
                        'already has one -- only one of them can project, and '
                        'nothing said which';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%already registered%' then raise; end if;
    end;
    raise notice 'query/04: a table projects into exactly one entity type';
end $$;

-- A table with no `id uuid` is refused at registration. It used to register,
-- and then every insert into it failed inside the generated projection trigger
-- with `column n.id does not exist` -- the table unusable, the registry row
-- describing it as fine (found by scenarios/tour).
do $$
declare v_msg text;
begin
    create table t_s1.keyed_naturally (key text primary key, label text);
    begin
        perform aiq.register_entity_table('ttype_natural', 't_s1.keyed_naturally', 'n.key');
        raise exception 'a table with no id column was registered as an entity type';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%no `id uuid` column%' then raise; end if;
    end;
    insert into t_s1.keyed_naturally values ('still-writable', 'x');
    raise notice 'query/04: an entity table without id uuid is refused before it can break inserts';
end $$;

-- ---------------------------------------------------------------------
-- 6. THE PROJECTION IS STATEMENT-LEVEL (D6), AND THAT IS THE SCALE ARGUMENT.
--
-- "a bulk COPY pays ONE set-based INSERT here, not 10k trigger firings"
-- (brief.md §5). Asserted off the catalog, because the alternative -- timing a
-- large load -- measures the machine rather than the design.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
    for r in select tgname, (tgtype & 1) = 1 as is_row
               from pg_trigger
              where tgrelid = 'public.demo_t_widget'::regclass and not tgisinternal
    loop
        if r.is_row then
            raise exception 'trigger % is FOR EACH ROW -- a 10k-row load would '
                            'pay 10k projections (D6)', r.tgname;
        end if;
    end loop;
    raise notice 'query/04: projection triggers are statement-level';
end $$;

-- ---------------------------------------------------------------------
-- 7. BULK LOAD WITH TRIGGERS OFF, THEN REBUILD, EQUALS THE LIVE PROJECTION.
--
-- graph-identity.md "Bulk load" and verification bullet 6: the rebuild uses
-- the SAME predicate as the trigger (both read it from entity_registry), so
-- a rebuild cannot widen the inclusion policy and resurrect an evicted node.
-- Both halves are asserted: what the rebuild ADDS, and what it must not.
-- ---------------------------------------------------------------------
do $$
declare v_added bigint; v_id uuid; v_excluded uuid;
begin
    alter table demo_t_widget disable trigger trg_aiq_project_ins;
    insert into demo_t_widget (name) values ('Bulk Loaded') returning id into v_id;
    insert into demo_t_widget (name, listed) values ('Bulk Excluded', false)
    returning id into v_excluded;
    alter table demo_t_widget enable trigger trg_aiq_project_ins;

    if exists (select 1 from aiq.nodes where entity_id = v_id) then
        raise exception 'disabling the trigger did not disable the projection';
    end if;
    if not exists (select 1 from aiq.check_drift('ttype_widget')
                    where direction = 'missing_node' and entity_id = v_id) then
        raise exception 'check_drift did not notice a row loaded with the '
                        'projection off -- the detector is the only thing '
                        'standing between a bulk load and a silent gap';
    end if;

    v_added := aiq.rebuild_entity_type('ttype_widget');
    if not exists (select 1 from aiq.lookup('Bulk Loaded')) then
        raise exception 'rebuild did not project the bulk-loaded row';
    end if;
    if exists (select 1 from aiq.nodes where entity_id = v_excluded) then
        raise exception
            'rebuild projected a row the live trigger would have excluded -- a '
            'rebuild that widens the predicate resurrects evicted nodes';
    end if;
    if exists (select 1 from aiq.check_drift('ttype_widget')) then
        raise exception 'drift remains after a rebuild that was supposed to repair it';
    end if;
    raise notice 'query/04: rebuild reproduces the live projection exactly (% nodes)',
        v_added;
end $$;

-- ---------------------------------------------------------------------
-- 8. DELETE: KEYS AND SOFT EDGES FOLLOW, HARD LINKS DO NOT.
--
-- graph-identity.md verification: "Delete an included entity; keys go;
-- incident soft edges go; hard junctions follow their own FK rules."
-- ---------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid; v_na uuid; v_nb uuid;
begin
    insert into demo_t_widget (name) values ('Doomed') returning id into v_a;
    insert into demo_t_widget (name) values ('Survivor') returning id into v_b;
    select node_id into v_na from aiq.lookup('Doomed');
    select node_id into v_nb from aiq.lookup('Survivor');

    insert into aiq.relation_types (src_type, relation, dst_type)
    values ('ttype_widget','t_links','ttype_widget') on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation) values (v_na, v_nb, 't_links');

    delete from demo_t_widget where id = v_a;

    if exists (select 1 from aiq.nodes where id = v_na) then
        raise exception 'deleting the typed row left its node';
    end if;
    if exists (select 1 from aiq.node_keys where node_id = v_na) then
        raise exception 'keys outlived their node';
    end if;
    if exists (select 1 from aiq.edges where src_id = v_na or dst_id = v_na) then
        raise exception 'a soft edge outlived one of its endpoints -- invariant 2';
    end if;
    if not exists (select 1 from aiq.nodes where id = v_nb) then
        raise exception 'the surviving endpoint was taken down with the edge';
    end if;
    raise notice 'query/04: delete cascades through keys and incident soft edges';
end $$;

-- ---------------------------------------------------------------------
-- 9. THE EDGE CATALOGUE, AND THE MESSAGE IT REFUSES WITH.
--
-- Both halves matter. An unlisted (src_type, relation, dst_type) triple must
-- be refused -- that is what keeps typos from becoming relations -- and the
-- refusal has to name the triple correctly. It did not: RAISE reads `%` as
-- the placeholder, so a format string written with `%s` appended a literal
-- 's' to every value and the error read
--     relation (companys, competes_withs, persons)
-- sending the reader to look for an entity type that does not exist.
-- ---------------------------------------------------------------------
do $$
declare v_msg text; v_na uuid; v_nb uuid;
begin
    insert into demo_t_widget (name) values ('Cat A');
    insert into demo_t_widget (name) values ('Cat B');
    select node_id into v_na from aiq.lookup('Cat A');
    select node_id into v_nb from aiq.lookup('Cat B');
    begin
        insert into aiq.edges (src_id, dst_id, relation)
        values (v_na, v_nb, 'invented_relation');
        raise exception 'an uncatalogued relation was accepted';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%not in the catalogue%' then raise; end if;
        if v_msg not like '%(ttype_widget, invented_relation, ttype_widget)%' then
            raise exception 'the refusal misnames the triple it refused: %', v_msg;
        end if;
    end;

    -- UPDATE is checked too, not just INSERT: an edge that was legal when
    -- written must not become illegal by being repointed.
    insert into aiq.edges (src_id, dst_id, relation) values (v_na, v_nb, 't_links');
    begin
        update aiq.edges set relation = 'invented_relation'
         where src_id = v_na and dst_id = v_nb;
        raise exception 'an edge was UPDATED to an uncatalogued relation';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%not in the catalogue%' then raise; end if;
    end;
    raise notice 'query/04: the edge catalogue is enforced, and says what it refused';
end $$;

-- ---------------------------------------------------------------------
-- 10. A KEY THAT CANNOT BE DERIVED FAILS THE WRITE, ATOMICALLY.
--
-- A key_expr that evaluates to NULL aborts the typed INSERT on node_keys'
-- not-null constraint. That is the right outcome -- a node with no key is
-- unLOOKUP-able, which fails the inclusion policy's own first clause -- and
-- the property worth pinning is that it fails WHOLE: no node is left behind
-- without its name.
-- ---------------------------------------------------------------------
do $$
begin
    begin
        insert into demo_t_widget (name) values (null);
        raise exception 'a row with no derivable key was projected';
    exception when not_null_violation then
        null;
    end;
    if exists (select 1 from aiq.nodes nd
                where nd.entity_type = 'ttype_widget'
                  and not exists (select 1 from aiq.node_keys k where k.node_id = nd.id)) then
        raise exception 'a node exists with no key at all -- the projection is '
                        'not atomic across nodes and node_keys';
    end if;
    raise notice 'query/04: an underivable key fails the write whole';
end $$;

-- ---------------------------------------------------------------------
-- 11. add_node_key IS THE ONLY WAY IN, AND IT REFUSES THE CANONICAL KIND.
--
-- Invariant 5: application code never writes nodes or node_keys except
-- through the projection. The projection derives exactly one key per row, so
-- short keys and aliases -- two thirds of LOOKUP's cascade -- had no write
-- path the invariant permitted. They now have one, and it must not become a
-- back door into the derived kind.
-- ---------------------------------------------------------------------
do $$
declare v_msg text;
begin
    insert into demo_t_widget (name) values ('Kyiv');
    perform aiq.add_node_key('Kyiv', 'Kiev', 'alias');
    if (select node_id from aiq.lookup('kiev')) is distinct from
       (select node_id from aiq.lookup('Kyiv')) then
        raise exception 'an alias does not resolve to the node it names';
    end if;
    if (select match_kind from aiq.lookup('kiev')) is distinct from 'alias' then
        raise exception 'the cascade does not report which kind matched';
    end if;

    begin
        perform aiq.add_node_key('Kyiv', 'Kyyiv', 'canonical');
        raise exception 'add_node_key wrote a canonical key -- that is the '
                        'projection''s, and a node with two of them has no '
                        'derived name at all';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%projection%' then raise; end if;
    end;

    -- An ambiguous target is refused rather than resolved by picking one:
    -- attaching a name to the wrong node reads back as if it were right.
    insert into demo_t_widget (name) values ('Twin');
    perform aiq.add_node_key('Twin', 'twinned', 'short');
    insert into demo_t_widget (name, org_id) values
        ('Twin B', 'a0000000-0000-0000-0000-00000000000a');
    perform aiq.add_node_key('Twin B', 'twinned', 'short');
    begin
        perform aiq.add_node_key('twinned', 'twinnest', 'alias');
        raise exception 'add_node_key resolved an ambiguous name by choosing one';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%resolves to%' then raise; end if;
    end;
    raise notice 'query/04: aliases have a write path, and it refuses canonical';
end $$;

-- ---------------------------------------------------------------------
-- 12. THE REGISTRY IS NOT A COPY OF THE PAYLOAD (INVARIANT 1).
--
-- `nodes` carries identity and a summary and nothing else. The day somebody
-- adds a column here to save a join is the day the graph has two sources of
-- truth for an attribute, and this is cheaper to assert than to notice.
-- ---------------------------------------------------------------------
do $$
declare v_extra text;
begin
    select string_agg(attname, ', ') into v_extra
    from pg_attribute
    where attrelid = 'aiq.nodes'::regclass and attnum > 0 and not attisdropped
      -- owner_id and visibility join org_id on this list rather than counting
      -- as payload, and the distinction the invariant is actually making is
      -- worth stating: it forbids ATTRIBUTES OF THE ENTITY -- a company's
      -- ticker, a person's role -- because those have a typed table that owns
      -- them and a second copy here would be a second source of truth. Who may
      -- SEE the node is not an attribute of the company; it is a property of
      -- the registry row, it has no typed table to live in, and the projection
      -- derives it from the source rather than duplicating a source column.
      and attname not in ('id','entity_type','entity_id','org_id','owner_id',
                          'visibility','summary','created_at','updated_at');
    if v_extra is not null then
        raise exception
            'aiq.nodes has grown payload columns (%). Typed tables own '
            'attributes; the registry owns identity (invariant 1)', v_extra;
    end if;
    raise notice 'query/04: the node registry still stores identity, not payload';
end $$;

-- ---------------------------------------------------------------------
-- THE RESOLUTION LEDGER (D11). Merges are records, and unresolve works.
--
-- D11 has specified this since graph-identity.md was written and it was the
-- last absence on the identity pipeline: a consumer building all three stages
-- on these surfaces had a substrate call for every step except recording what
-- it decided, and wrote its clusters to a local table instead.
--
-- The properties asserted here are the three the table exists for -- the record
-- survives, neither constituent is destroyed, and the reversal is mechanical --
-- plus the one that is easy to get wrong: resolution must NOT change what a
-- traversal returns, or every existing caller's meaning changes the day
-- somebody runs a resolver.
-- ---------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid; v_res uuid; v_n int; v_before int; v_after int;
begin
    insert into aiq.nodes (entity_type, entity_id)
    values ('soft', gen_random_uuid()) returning id into v_a;
    insert into aiq.nodes (entity_type, entity_id)
    values ('soft', gen_random_uuid()) returning id into v_b;
    insert into aiq.node_keys (node_id, entity_type, key, kind)
    values (v_a, 'soft', 't_res_acme corp', 'canonical'),
           (v_b, 'soft', 't_res_acme corporation', 'canonical');

    -- An edge on the node that is about to be merged, so "neither constituent
    -- is deleted" is asserted against something that would visibly disappear.
    insert into aiq.edges (src_id, dst_id, relation) values (v_b, v_a, 'mentions');
    select count(*) into v_before from aiq.edges where src_id = v_b;

    v_res := aiq.resolve_nodes(v_a, v_b, 'llm', 'test-resolver',
                               '{"score":0.91}'::jsonb);

    -- 1. The record exists, and it says what KIND of assertion it was.
    select count(*) into v_n from aiq.node_resolutions
     where id = v_res and tier = 'llm' and decided_by = 'test-resolver'
       and evidence->>'score' = '0.91' and undone_at is null;
    if v_n <> 1 then
        raise exception 'the merge left no inspectable record';
    end if;

    -- 2. The merged node still exists and still has its edges.
    if not exists (select 1 from aiq.nodes where id = v_b) then
        raise exception 'the merged node was deleted -- D11 says neither constituent is';
    end if;
    select count(*) into v_after from aiq.edges where src_id = v_b;
    if v_after <> v_before then
        raise exception 'edges on the merged node went from % to %', v_before, v_after;
    end if;

    -- 3. The name moved: the survivor answers to it, the merged node does not,
    --    so LOOKUP stops returning two nodes for one thing.
    if not exists (select 1 from aiq.node_keys
                    where node_id = v_a and key = 't_res_acme corporation'
                      and kind = 'alias') then
        raise exception 'the merged node''s name did not move to the survivor';
    end if;
    if exists (select 1 from aiq.node_keys
                where node_id = v_b and kind = 'canonical') then
        raise exception 'the merged node kept its canonical key -- LOOKUP still splits';
    end if;

    -- 4. node_current applies it, transitively, and is safe to join on a node
    --    that was never merged.
    if (select current_id from aiq.node_current where node_id = v_b) is distinct from v_a then
        raise exception 'node_current does not follow the resolution';
    end if;
    if (select current_id from aiq.node_current where node_id = v_a) is distinct from v_a then
        raise exception 'an unmerged node does not map to itself';
    end if;

    -- 5. AND THE TRAVERSAL DID NOT CHANGE. This is the assertion that keeps
    --    D11 a record rather than an index behaviour.
    if not exists (select 1 from aiq.graph_neighbors(v_b, 'mentions')) then
        raise exception
            'graph_neighbors stopped returning the merged node''s edges. That may '
            'be an improvement, but D11 says resolution is a RECORD -- update the '
            'document and invert this assertion rather than deleting it, so every '
            'existing caller''s change of meaning is a deliberate act';
    end if;

    -- 6. A second merge of the same node is refused while the first stands.
    begin
        perform aiq.resolve_nodes(v_a, v_b, 'human', 'test');
        raise exception 'a node was merged into two survivors at once';
    exception when unique_violation then null;
    end;

    -- 7. A cycle is refused rather than left for the view to loop on.
    begin
        perform aiq.resolve_nodes(v_b, v_a, 'human', 'test');
        raise exception 'a resolution cycle was accepted';
    exception when others then
        if sqlerrm like '%cycle was accepted%' then raise; end if;
    end;

    -- 8. Unresolve is mechanical: the name goes back, the row stays.
    perform aiq.unresolve_node(v_res, 'test-human');
    if not exists (select 1 from aiq.node_keys
                    where node_id = v_b and key = 't_res_acme corporation'
                      and kind = 'canonical') then
        raise exception 'unresolve did not restore the canonical key';
    end if;
    if exists (select 1 from aiq.node_keys
                where node_id = v_a and key = 't_res_acme corporation'
                  and kind = 'alias') then
        raise exception 'the survivor still answers to the name it gave back';
    end if;
    if (select current_id from aiq.node_current where node_id = v_b) is distinct from v_b then
        raise exception 'node_current still applies an undone resolution';
    end if;
    if not exists (select 1 from aiq.node_resolutions
                    where id = v_res and undone_at is not null) then
        raise exception
            'the undone resolution was deleted. A ledger that forgets its '
            'reversals is not a ledger -- the row is kept and stamped';
    end if;

    -- 9. And the pair can be resolved again afterwards, with both attempts on
    --    the record. `unique (merged_id) where undone_at is null` is what makes
    --    that possible, and it is easy to write as a plain unique by accident.
    perform aiq.resolve_nodes(v_a, v_b, 'human', 'test-again');
    select count(*) into v_n from aiq.node_resolutions where merged_id = v_b;
    if v_n <> 2 then
        raise exception 'the second merge replaced the first instead of joining it';
    end if;

    raise notice 'graph-identity: merges are records, nothing is destroyed, and unresolve works';
end $$;

rollback;
