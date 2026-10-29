# Step 2: the coverage certificate. A walk can say when it is done without the answer key: once no accepted lead
# that points at ten or fewer unread items is left open, everything the specific clues reach has been read.
#
# walk-0 is a synthetic world with a known answer (q6 has 3 pieces of evidence). It has no words, so every clue's P
# comes from the world's own decider, stored as q6's replay: 'offline' asks nobody and costs $0. The walk runs until
# it reads nothing new -- up to 20 waves of 320 reads -- so it is installed once more under its own name.
# walk-0's replay answers every lead, so any settings work; the walk is pinned to span 2 and cap 10, the defaults
# before 0.2.33, which the article's counts were taken under.
psql "$P8_DSN" -Atc "select aiq.install_walk_workflow('walk_20', p_waves => 20)" > /dev/null
RUN=$(psql "$P8_DSN" -Atc "
  select workflow.start_workflow('walk_20', jsonb_build_object(
           'question', jsonb_build_object('id', r.metadata->>'id', 'text', r.metadata->>'text'), 'nodes', 'world_item', 'prefix', 'walk-0/',
           'replay', 'replay:' || (r.metadata->>'id'), 'offline', true,
           'settings', jsonb_build_object('wave', 320, 'waves', 20, 'span', 2, 'cap', 10)))
    from content.resources r where r.uri = 'question:walk-0/q6'")
until [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$RUN'")" != running ]; do sleep 2; done

psql "$P8_DSN" -v run="$RUN" -v labelled="$(python3 build/labels.py samples/walk-0/questions.jsonl walk-0/q6)" <<'SQL'
-- Why it stopped: 'dry' means a wave read nothing new, after every earlier read's clues were judged.
select aiq.walk_summary(:'run')->'stop' as stop;

-- The countdown. A lead is specific when it points at ten or fewer items not yet read; it is open while it is
-- accepted and not yet travelled. A wave's own reads raise clues that the next wave judges, so they count as open
-- here too. The evidence columns use the world's answer key, which the harness passes in; the walk never holds it.
with c as materialized (select * from aiq.walk_clues(:'run')),
     r as materialized (select * from aiq.walk_reads(:'run')),
     w as (select wave, (select count(*) from r x where x.wave <= w.wave)::int as reads
             from (select distinct wave from r where wave > 0) w),
     cov as (select * from aiq.walk_coverage(:'run', :'labelled', array(select reads from w)))
select w.wave, w.reads,
       (select count(*) from c where c.decision = 'accepted' and c.wave <= w.wave + 1
           and (c.travelled_wave is null or c.travelled_wave > w.wave)
           and (select count(*) from unnest(c.targets) t
                 where not exists (select 1 from r x where x.doc = t and x.wave <= w.wave)) between 1 and 10)
         as specific_open,
       cov.walk as evidence_read, cov.labelled as evidence
  from w join cov on cov.k = w.reads order by 1;
SQL
