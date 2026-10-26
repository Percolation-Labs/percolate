# Step 2: the coverage certificate. A walk can say when it is done without the answer key: once no accepted lead
# that points at ten or fewer unread items is left open, everything the specific clues reach has been read.
#
# walk-0 is a synthetic world with a known answer (q6 has 3 pieces of evidence). It has no words, so every clue's P
# comes from the world's own decider, stored as q6's replay: 'offline' asks nobody and costs $0. The walk runs until
# it reads nothing new -- up to 20 waves of 320 reads -- so it is installed once more under its own name.
psql "$P8_DSN" -Atc "select aiq.install_walk_workflow('walk_20', p_waves => 20)" > /dev/null
RUN=$(psql "$P8_DSN" -Atc "
  select workflow.start_workflow('walk_20', jsonb_build_object(
           'question', r.metadata, 'nodes', 'world_item', 'prefix', 'walk-0/',
           'replay', 'replay:' || (r.metadata->>'id'), 'offline', true,
           'settings', jsonb_build_object('wave', 320, 'waves', 20)))
    from content.resources r where r.uri = 'question:walk-0/q6'")
until [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$RUN'")" != running ]; do sleep 2; done

psql "$P8_DSN" -v run="$RUN" <<'SQL'
-- Why it stopped: 'dry' means a wave read nothing new, after every earlier read's clues were judged.
select aiq.walk_summary(:'run')->'stop' as stop;

-- The countdown. A lead is specific when it points at ten or fewer items not yet read; it is open while it is
-- accepted and not yet travelled. A wave's own reads raise clues that the next wave judges, so they count as open
-- here too. The evidence column uses the answer key, which rides in the run's question; the walk never reads it.
with c as materialized (select * from aiq.walk_clues(:'run')),
     r as materialized (select * from aiq.walk_reads(:'run')),
     gold as (select jsonb_array_elements_text(aiq.walk_summary(:'run')->'question'->'gold') as doc),
     w as (select distinct wave from r where wave > 0)
select w.wave,
       (select count(*) from r where r.wave <= w.wave) as reads,
       (select count(*) from c where c.decision = 'accepted' and c.wave <= w.wave + 1
           and (c.travelled_wave is null or c.travelled_wave > w.wave)
           and (select count(*) from unnest(c.targets) t
                 where not exists (select 1 from r x where x.doc = t and x.wave <= w.wave)) between 1 and 10)
         as specific_open,
       (select count(*) from gold g where exists (select 1 from r x where x.doc = g.doc and x.wave <= w.wave))
         as evidence_read,
       (select count(*) from gold) as evidence
  from w order by 1;
SQL
