-- AN ITERATED SEMANTIC JOIN: A WALK WHOSE RELATION IS A WILDCARD (REM-997).
--
-- aiq.iterated_join walks from a seed key until it reaches a node of the
-- target type, joining each round through whichever link reaches further:
-- a stored edge, a key two nodes share, key similarity at a threshold, or a
-- judge. Every hop says which kind of link it was. The study is Percolate
-- writing ld-436bceb0b31c; this is its first runnable slice.
--
-- Reads the committed graph sample (dev/init/04-graph-sample.sql). The judge
-- is a stub in this transaction, because the point is the interface: a walk
-- asked for a judged link with no judge configured is refused by name.
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

do $$
begin
    if not exists (select 1 from aiq.node_keys where key = 'borealis strike') then
        raise exception 'the graph sample is not loaded: dev/init/04-graph-sample.sql';
    end if;
end $$;

-- A deterministic judge: it links Tomas Lindqvist to Nadler, and nothing else.
create function pg_temp.judge(p_criterion text, p_frontier uuid[])
returns table(src uuid, dst uuid, p real) language sql stable as $$
    select t.node_id, n.node_id, 0.9::real
      from aiq.node_keys t, aiq.node_keys n
     where t.key = 'tomas lindqvist' and n.key = 'nadler'
       and t.node_id = any (p_frontier)
$$;

do $$
declare r record; v_n int; v_err text;
begin
    -- 1. Stored edges resolve it: the strike mentions Borealis, where Priya works.
    select * into r from aiq.iterated_join('borealis strike', 'person', 3);
    if r.resolved is distinct from true or r.key is distinct from 'priya raman' or r.round is distinct from 2 then
        raise exception '1: expected priya raman in round 2, got %', row_to_json(r);
    end if;
    if (select array_agg(h->>'link' order by o) from jsonb_array_elements(r.path) with ordinality x(h, o))
       is distinct from array['edge', 'edge'] then
        raise exception '1: expected two edge hops, got %', r.path;
    end if;

    -- 2. A shared key resolves it when edges are out of range: the event and
    --    the company both hold the key "borealis".
    select * into r from aiq.iterated_join('borealis strike', 'company', 2, p_links => array['key']);
    if r.resolved is distinct from true or r.key is distinct from 'borealis'
       or r.path->0->>'link' is distinct from 'key' or r.path->0->>'via' is distinct from 'borealis' then
        raise exception '2: expected a key link to borealis, got %', row_to_json(r);
    end if;

    -- 3. Similarity resolves it, at a threshold and never by rank.
    select * into r from aiq.iterated_join('acme q3 results', 'company', 1, 50, 0.3, p_links => array['similarity']);
    if r.resolved is distinct from true or r.key is distinct from 'acme'
       or r.path->0->>'link' is distinct from 'similarity' or (r.path->0->>'score')::numeric < 0.3 then
        raise exception '3: expected a similarity link to acme at >= 0.3, got %', row_to_json(r);
    end if;
    select count(*) into v_n
      from aiq.iterated_join('acme q3 results', 'company', 1, 50, 0.4, p_links => array['similarity']) x
     where x.resolved;
    if v_n <> 0 then
        raise exception '3: at 0.4 the 0.313 match must not be taken';
    end if;

    -- 4. A wildcard that does not resolve says so, rather than returning nothing.
    select * into r from aiq.iterated_join('tomas lindqvist', 'company', 3);
    if r.resolved is distinct from false or r.path->>'reason' not like 'nothing new to join%' then
        raise exception '4: tomas lindqvist reaches nothing, got %', row_to_json(r);
    end if;

    -- 5. The bound is the walk's, not the graph's.
    select * into r from aiq.iterated_join('priya raman', 'port', 2);
    if r.resolved is distinct from false or r.path->>'reason' not like 'the bound was reached%' then
        raise exception '5: two rounds cannot reach a port, got %', row_to_json(r);
    end if;
    begin
        perform aiq.iterated_join('priya raman', 'port', 6);
        raise exception '5: six rounds were accepted';
    exception when others then
        get stacked diagnostics v_err = message_text;
        if v_err not like '%between 1 and 5%' then raise; end if;
    end;

    -- 6. A judged link with no judge configured is refused by name.
    begin
        perform aiq.iterated_join('tomas lindqvist', 'company', 2, p_criterion => 'competes for the same accounts');
        raise exception '6: a criterion with no judge was accepted';
    exception when feature_not_supported then
        get stacked diagnostics v_err = message_text;
        if v_err not like '%no judge is configured%' then raise; end if;
    end;

    -- 7. A configured judge plugs in, and its hop is marked judged.
    perform set_config('percolate.link_judge', 'pg_temp.judge', true);
    select * into r from aiq.iterated_join('tomas lindqvist', 'company', 2,
                                           p_criterion => 'competes for the same accounts');
    if r.resolved is distinct from true or r.key is distinct from 'nadler'
       or r.path->0->>'link' is distinct from 'judged'
       or r.path->0->>'via' is distinct from 'competes for the same accounts' then
        raise exception '7: expected a judged link to nadler, got %', row_to_json(r);
    end if;

    -- 8. A seed key two nodes hold is refused, never picked.
    begin
        perform aiq.iterated_join('borealis', 'person', 2);
        raise exception '8: an ambiguous seed was accepted';
    exception when others then
        get stacked diagnostics v_err = message_text;
        if v_err not like '%names 2 nodes%' then raise; end if;
    end;
end $$;

select 'iterated join: ok' as result;

rollback;
