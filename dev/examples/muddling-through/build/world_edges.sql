-- Items and tags become nodes, readable by anyone: the world is public sample data.
select aiq.register_entity_table(
    p_entity_type => 'world_item', p_source_table => 'walk_world.items', p_key_expr => 'n.key',
    p_summary_expr => 'n.key', p_visibility_expr => $$'public'$$);
select aiq.register_entity_table(
    p_entity_type => 'world_tag', p_source_table => 'walk_world.tags', p_key_expr => 'n.key',
    p_summary_expr => 'n.key', p_visibility_expr => $$'public'$$);
select aiq.register_entity_table(
    p_entity_type => 'world_question', p_source_table => 'walk_world.questions', p_key_expr => 'n.key',
    p_summary_expr => 'n.phrasing', p_visibility_expr => $$'public'$$);
select aiq.rebuild_entity_type('world_item');
select aiq.rebuild_entity_type('world_question');
select aiq.rebuild_entity_type('world_tag');

insert into aiq.relation_types (src_type, relation, dst_type, description, is_symmetric) values
    ('world_item', 'walk_tagged',  'world_tag',  'the item carries the tag; provenance {n}, its members (REM-1203)', false),
    ('world_item', 'walk_next',    'world_item', 'the next item in the sitting; provenance {sitting, pos} (REM-1203)', false),
    ('world_item', 'walk_nearest', 'world_item', 'one of the item''s 3 nearest in meaning; provenance {rank} (REM-1203)', false),
    ('world_question', 'walk_seed', 'world_item', 'search''s order for the question; provenance {rank} (REM-1203)', false)
on conflict (src_type, relation, dst_type) do update set description = excluded.description;

-- The edges, by construction: weight 1, and the provenance says how each was derived.
insert into aiq.edges (src_id, dst_id, relation, provenance)
select a.id, b.id, 'walk_tagged', jsonb_build_object('n', t.n)
  from walk_world.tagged x join walk_world.tags t on t.id = x.tag
  join aiq.nodes a on a.entity_type = 'world_item' and a.entity_id = x.item
  join aiq.nodes b on b.entity_type = 'world_tag' and b.entity_id = x.tag
on conflict (src_id, dst_id, relation) do update set provenance = excluded.provenance, valid_to = null;
insert into aiq.edges (src_id, dst_id, relation, provenance)
select a.id, b.id, 'walk_next', jsonb_build_object('sitting', x.sitting, 'pos', x.pos)
  from walk_world.next x
  join aiq.nodes a on a.entity_type = 'world_item' and a.entity_id = x.a
  join aiq.nodes b on b.entity_type = 'world_item' and b.entity_id = x.b
on conflict (src_id, dst_id, relation) do update set provenance = excluded.provenance, valid_to = null;
insert into aiq.edges (src_id, dst_id, relation, provenance)
select a.id, b.id, 'walk_nearest', jsonb_build_object('rank', x.rank)
  from walk_world.nearest x
  join aiq.nodes a on a.entity_type = 'world_item' and a.entity_id = x.a
  join aiq.nodes b on b.entity_type = 'world_item' and b.entity_id = x.b
on conflict (src_id, dst_id, relation) do update set provenance = excluded.provenance, valid_to = null;
insert into aiq.edges (src_id, dst_id, relation, provenance)
select a.id, b.id, 'walk_seed', jsonb_build_object('rank', x.rank)
  from walk_world.seeds x
  join aiq.nodes a on a.entity_type = 'world_question' and a.entity_id = x.question
  join aiq.nodes b on b.entity_type = 'world_item' and b.entity_id = x.item
on conflict (src_id, dst_id, relation) do update set provenance = excluded.provenance, valid_to = null;
