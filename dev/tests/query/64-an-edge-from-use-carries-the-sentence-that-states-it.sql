-- AN EDGE FROM USE IS MADE ONLY WHERE ONE SENTENCE NAMES BOTH ENDS, AND IT CARRIES THAT SENTENCE.
--
-- aiq.use_edges (tutorial four; nothing in the walk calls it): after a walk read ue/1 (which names Snapper Foster)
-- and ue/2 (which names David Hasselhoff) without bridging them, it finds the unread paragraphs that hold both terms
-- and keeps one only if a sentence of it names both. aiq.use_edges_write stores that sentence on a 'walk_use' edge.
--   ue/3 names both in two sentences; the one closer to the question is kept.
--   ue/4 names both, but never in one sentence: no edge (no fallback sentence).
--   ue/5 names only one: not a candidate.
--   ue/7 names both in one sentence, so while unread it is an edge too, tied with ue/3 and after it by key; once
--        read it joins the pair, and with ue/7 among the reads nothing is proposed.
-- Writing the edge does not change the graph a walk reads. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table fu(n int, said text, terms text[]);
insert into fu values
 (1, 'Snapper Foster is a character on a daytime drama.', '{snapper foster,character}'),
 (2, 'David Hasselhoff is an actor and singer.', '{david hasselhoff,actor}'),
 (3, 'David Hasselhoff and Snapper Foster both appear in a long list of names. Early on, David Hasselhoff played Snapper Foster on the show The Young and the Restless.',
     '{david hasselhoff,snapper foster}'),
 (4, 'David Hasselhoff sings in Germany. Snapper Foster is a doctor.', '{david hasselhoff,snapper foster}'),
 (5, 'David Hasselhoff drove a talking car.', '{david hasselhoff}'),
 (7, 'A note that names David Hasselhoff and Snapper Foster together.', '{david hasselhoff,snapper foster}');

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'use_doc', gen_random_uuid(), org, 'public', said from fu;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select n.id, 'use_doc', 'ue/' || fu.n, 'canonical', org
      from fu join aiq.nodes n on n.entity_type = 'use_doc' and n.summary = fu.said;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'use_tag', gen_random_uuid(), org, 'public', t from fu, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('use_doc', 'walk_tagged', 'use_tag', 'query/64 fixture'),
        ('use_doc', 'walk_next', 'use_doc', 'query/64 fixture'),
        ('use_doc', 'walk_nearest', 'use_doc', 'query/64 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select d.id, tg.id, 'walk_tagged', org, '{}'
      from fu join aiq.nodes d on d.entity_type = 'use_doc' and d.summary = fu.said
      cross join unnest(fu.terms) t
      join aiq.nodes tg on tg.entity_type = 'use_tag' and tg.summary = t;
end $$;

do $$
declare
    inp  jsonb := jsonb_build_object('nodes', 'use_doc', 'prefix', 'ue/');
    q    text := 'Which show had the actor who played Snapper Foster?';
    got  text;
    g0   jsonb;
    n    int;
begin
    -- 1. ue/3, with its sentence closer to the question, and ue/7; ue/4 (both, never together) and ue/5 make none
    select string_agg(target || '|' || a || '|' || b || '|' || sentence, ' ;; ') into got
      from aiq.use_edges(inp, q, array['ue/1', 'ue/2'], 'ue/1', 3);
    if got is distinct from 'ue/3|david hasselhoff|snapper foster|Early on, David Hasselhoff played Snapper Foster on the show The Young and the Restless.'
                            || ' ;; ue/7|david hasselhoff|snapper foster|A note that names David Hasselhoff and Snapper Foster together.' then
        raise exception 'use_edges proposed %', got;
    end if;
    -- 2. a pair a read already joins proposes nothing
    select count(*) into n from aiq.use_edges(inp, q, array['ue/1', 'ue/2', 'ue/7'], 'ue/1', 3);
    if n <> 0 then
        raise exception 'with ue/7 read (it joins the pair) use_edges still proposed % edge(s)', n;
    end if;
    -- 3. the writer stores the sentence on a walk_use edge from the source, and the walk's graph is unchanged
    g0 := aiq.walk_graph_build(inp);
    select string_agg(target || '|' || sentence, ';') into got from aiq.use_edges_write(inp, q, array['ue/1', 'ue/2'], 'ue/1', 3);
    if (select e.provenance->>'sentence' from aiq.edges e
          join aiq.node_keys ks on ks.node_id = e.src_id and ks.key = 'ue/1'
          join aiq.node_keys kd on kd.node_id = e.dst_id and kd.key = 'ue/3'
         where e.relation = 'walk_use')
       is distinct from 'Early on, David Hasselhoff played Snapper Foster on the show The Young and the Restless.' then
        raise exception 'the walk_use edge ue/1 -> ue/3 does not carry the stated sentence (writer returned %)', got;
    end if;
    if (select g->'terms' = g0->'terms' and g->'post' = g0->'post' and g->'near' = g0->'near' and g->'beside' = g0->'beside'
          from aiq.walk_graph_build(inp) g) is distinct from true then
        raise exception 'writing an edge from use changed the graph a walk reads';
    end if;
    raise notice 'query/64: an edge from use is made only where one sentence names both ends, and it carries that sentence';
end $$;

rollback;
