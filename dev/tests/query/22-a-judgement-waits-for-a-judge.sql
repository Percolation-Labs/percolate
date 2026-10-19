-- What dream cannot decide waits for a judge, and the verdict is recorded (REM-1055).
--
-- A soft node with no exact typed target was a count in dream's receipt and
-- then a person's job by hand. Now it is a row in aiq.judgements, and a
-- connected agent claims it, decides, and the decision carries reason,
-- decided_by and tier. The checks, as a signed-in member:
--   1. dream queues the alias, once, with its candidates; a rule-decided name
--      is not queued;
--   2. claim returns it with how_to_decide; a second claimer gets nothing;
--   3. a bind to something that is not a candidate is refused, and so is a
--      verdict written straight onto the row by someone without the claim;
--   4. complete binds it: the resolution reads decided_by agent:<user>, tier
--      agent, and the judgement holds the resolution id; the same verdict
--      again is idempotent, a different one is refused;
--   5. release gives an item back with nothing recorded; a lapsed lease
--      cannot complete;
--   6. a second dream queues nothing new;
--   7. another soft node is a candidate -- an alias, or the same name as
--      another kind -- and a bind to it goes through.
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'judgements: %', p_what;
    end if;
end $$;

-- Knit names two companies loosely; one typed company exists with a name
-- close to the first; the second has an exact typed twin, which dream binds by
-- rule and must not queue.
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Ana Q22"},{"k":"company","n":"Acme Corp Q22"},{"k":"company","n":"Borealis Q22"},
  {"k":"company","n":"Zephyr Holdings Q22"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"},{"s":0,"t":3,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q22"}');
insert into demo.companies (id, name, org_id)
select gen_random_uuid(), 'Acme Corporation Q22', s.org_id from aiq.soft_nodes s where s.key = 'acme corp q22';
insert into demo.companies (id, name, org_id)
select gen_random_uuid(), 'Borealis Q22', s.org_id from aiq.soft_nodes s where s.key = 'borealis q22';

select aiq.dream() as first \gset
select pg_temp.check((:'first'::jsonb->>'queued_for_a_judge')::int >= 1, '1. dream queued nothing: ' || :'first');
select pg_temp.check(exists (select 1 from aiq.judgements where kind = 'bind' and status = 'open'
                                and evidence->>'key' = 'acme corp q22'
                                and jsonb_array_length(evidence->'candidates') >= 1),
    '1. the alias was not queued with a candidate');
select pg_temp.check(not exists (select 1 from aiq.judgements where evidence->>'key' = 'borealis q22'),
    '1. a name dream bound by rule was queued for a judge');
select id as acme_j from aiq.judgements where evidence->>'key' = 'acme corp q22' \gset
select id as zephyr_j from aiq.judgements where evidence->>'key' = 'zephyr holdings q22' \gset
select n.id as acme_typed from aiq.nodes n join aiq.node_keys k on k.node_id = n.id
 where k.key = 'acme corporation q22' and n.entity_type = 'company' limit 1 \gset

-- psql variables do not reach inside a DO block, so the ids go in as settings,
-- before the role switch.
select set_config('q22.acme', :'acme_j', true), set_config('q22.zephyr', :'zephyr_j', true),
       set_config('q22.typed', :'acme_typed', true);

-- A signed-in member. Claims are set before the role switch (set_config is not granted).
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

do $$
declare
    v_acme uuid := current_setting('q22.acme')::uuid;
    v_zephyr uuid := current_setting('q22.zephyr')::uuid;
    v_typed uuid := current_setting('q22.typed')::uuid;
    v jsonb; v_again jsonb; v_failed boolean;
begin
    -- 2. Claim, and the same claim again.
    v := aiq.claim_judgement(null, v_acme);
    perform pg_temp.check(v->>'id' = v_acme::text and v->>'status' = 'claimed'
                          and v->>'how_to_decide' like '%' || v_typed || '%',
        '2. claim did not return the item with how_to_decide naming the candidate: ' || v::text);
    perform pg_temp.check((aiq.claim_judgement(null, v_acme)->>'id')::uuid = v_acme,
        '2. re-claiming your own live claim should return the same item');

    -- Another member cannot take what is held.
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
    v_failed := false;
    begin
        perform aiq.claim_judgement(null, v_acme);
    exception when others then v_failed := true;
    end;
    perform pg_temp.check(v_failed, '2. a second member took an item somebody holds');
    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

    -- 3. A verdict written straight onto the row, by someone with no claim, is
    --    refused by the guard: complete_judgement is not the only way to UPDATE.
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
    v_failed := false;
    begin
        update aiq.judgements set status = 'decided', verdict = jsonb_build_object('decision','bind','target', v_typed),
                                  reason = 'forged', tier = 'agent'
         where id = v_acme;
    exception when others then v_failed := true;
    end;
    perform pg_temp.check(v_failed, '3. a verdict written onto the row without a claim was accepted');
    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

    -- 3. A bind to something that is not a candidate.
    v_failed := false;
    begin
        perform aiq.complete_judgement(v_acme, jsonb_build_object('decision','bind','target', gen_random_uuid()),
                                       'a guess', 'agent');
    exception when others then v_failed := true;
    end;
    perform pg_temp.check(v_failed, '3. a bind to a non-candidate was applied');

    -- 4. Bind it.
    v := aiq.complete_judgement(v_acme, jsonb_build_object('decision','bind','target', v_typed),
                                'Acme Corp is how the Acme Corporation is named in the sessions', 'agent');
    perform pg_temp.check(v->>'status' = 'decided' and jsonb_array_length(v->'resolution_ids') = 1
                          and v->>'decided_by' = 'agent:11111111-1111-1111-1111-111111111111'
                          and v->>'tier' = 'agent',
        '4. complete did not decide and report the resolution: ' || v::text);
    v_again := aiq.complete_judgement(v_acme, jsonb_build_object('decision','bind','target', v_typed), 'again', 'agent');
    perform pg_temp.check(v_again->>'already' = 'true', '4. the same verdict again was not idempotent: ' || v_again::text);
    v_failed := false;
    begin
        perform aiq.complete_judgement(v_acme, '{"decision":"none"}', 'changed my mind', 'agent');
    exception when others then v_failed := true;
    end;
    perform pg_temp.check(v_failed, '4. a different verdict after the decision was accepted');

    -- 5. Release gives it back; a lapsed lease cannot complete.
    v := aiq.claim_judgement(null, v_zephyr);
    perform pg_temp.check(v->>'status' = 'claimed', '5. could not claim the second item: ' || v::text);
    perform pg_temp.check(aiq.release_judgement(v_zephyr)->>'status' = 'open', '5. release did not reopen the item');
    v := aiq.claim_judgement(null, v_zephyr, interval '1 second');
    perform pg_sleep(1.2);
    v_failed := false;
    begin
        perform aiq.complete_judgement(v_zephyr, '{"decision":"none"}', 'no candidate fits', 'agent');
    exception when others then v_failed := true;
    end;
    perform pg_temp.check(v_failed, '5. a complete after the lease lapsed was applied');
end $$;

reset role;

-- 4, from the ledger's side.
select pg_temp.check(exists (select 1 from aiq.node_resolutions r
                              where r.canonical_id = :'acme_typed' and r.tier = 'agent'
                                and r.decided_by = 'agent:11111111-1111-1111-1111-111111111111'
                                and r.evidence->>'judgement' = :'acme_j'),
    '4. the resolution does not record tier agent, the agent and the judgement');
select pg_temp.check((select s.resolved_node_id is not null from aiq.soft_nodes s where s.key = 'acme corp q22'),
    '4. the soft node was not promoted');
select pg_temp.check((select status in ('open','claimed') and verdict is null and decided_at is null from aiq.judgements where id = :'zephyr_j'),
    '5. the released, then lapsed, item should still be undecided with nothing recorded');

-- 6. A second dream queues nothing new.
select aiq.dream() as second \gset
select pg_temp.check((:'second'::jsonb->>'queued_for_a_judge')::int = 0, '6. a second dream queued again: ' || :'second');

-- 7. A soft name's twin is another soft name (jack, 20 Oct): an alias of the
--    same kind, and the same name claimed as another kind, are candidates, and
--    the bind to the alias goes through. Knit lands as the engine, with no
--    member's claims set: the member's would make these nodes theirs alone.
set local request.jwt.claims = '';
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Ana Costa Q22"},{"k":"company","n":"Tagus Q22"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q22-twins-1"}');
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"A. Costa Q22"},{"k":"organization","n":"Tagus Q22"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q22-twins-2"}');
select aiq.dream() as third \gset
select id as costa_j from aiq.judgements where evidence->>'key' = 'a. costa q22' and status = 'open' \gset
select k.node_id as ana_soft from aiq.node_keys k where k.key = 'person/ana costa q22' and k.kind = 'canonical' \gset
select pg_temp.check(exists (select 1 from aiq.judgements j, jsonb_array_elements(j.evidence->'candidates') c
                              where j.id = :'costa_j' and c->>'node_id' = :'ana_soft' and c->>'candidate' = 'soft'),
    '7. the alias A. Costa did not get the soft node Ana Costa as a candidate');
select pg_temp.check(exists (select 1 from aiq.judgements j, jsonb_array_elements(j.evidence->'candidates') c
                              where j.evidence->>'key' = 'tagus q22' and j.evidence->>'claimed_kind' = 'organization'
                                and c->>'candidate' = 'soft, claimed as company'),
    '7. Tagus as organization did not get Tagus as company as a candidate');
select set_config('q22.costa', :'costa_j', true), set_config('q22.ana', :'ana_soft', true);
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;
select (aiq.claim_judgement(null, current_setting('q22.costa')::uuid)->>'status') = 'claimed' as claimed_costa \gset
select aiq.complete_judgement(current_setting('q22.costa')::uuid,
         jsonb_build_object('decision','bind','target', current_setting('q22.ana')),
         'same initial and surname, same company, same sessions', 'agent') as bound \gset
reset role;
select pg_temp.check(:'claimed_costa'::boolean and jsonb_array_length(:'bound'::jsonb->'resolution_ids') = 1,
    '7. the bind of A. Costa to the soft node Ana Costa did not go through: ' || :'bound');

\echo 'query/22: dream queues what it cannot decide; an agent claims, binds, and the verdict is recorded'
rollback;
