-- ============================================================================
-- THE CLUE WALK AS A WORKFLOW (REM-1210)
-- ============================================================================
--
-- A walk answers one question by reading in waves. Search supplies the first
-- reads. Every read raises CLUES: a term it shares with a few unread
-- documents, the documents beside it in its sitting, the documents nearest it
-- in meaning. A decider (Jev) gives each clue a P; P >= 0.5 accepts it; and
-- the wave then travels the accepted clues, best first, reading what they
-- reach until it holds its share of reads. The decider acts BEFORE the read:
-- a judgement after a row is read has already paid for the row.
--
-- WHY A WORKFLOW AND NOT A CLIENT LOOP. The same walk existed as Python
-- around the database (percolate-core `percolate walk run`). A reader could
-- not see which part was Percolate. Here every step is a task row, and every
-- read, clue, P, gate decision, open lead and the stop can be queried with
-- SQL: aiq.walk_reads, aiq.walk_clues, aiq.walk_waves, aiq.walk_summary.
--
--     start   sql    the seeds: search's first reads (wave 0)
--     wave    repeat, at most 20 waves, until a wave finds nothing to read
--       judge   matrix of rest: one Jev request per 60 clues the replay lacks
--       read    sql    gate the wave's clues, travel the best, read to the wave's size
--
-- NO NEW TABLE. A walk's record is its run's own task rows. The 64KB task cap
-- decides the split: a read step records only its reads and travels (a few
-- kilobytes), each judge child records one Jev request and its answers, and
-- everything else -- which clues a wave raised, their targets, which stayed
-- open -- is recomputed by aiq.walk_state from those rows and from the links
-- as they stood when the run started. The links are by construction
-- (REM-1201: walk_term, walk_tagged, walk_next, walk_nearest), so the
-- recomputation is exact, not a model's second opinion.
--
-- A WAVE IS ONE JUDGING ROUND. The study judged after every travel step,
-- about ten rounds a wave; a workflow judges once a wave, which is what the
-- article's figure shows (read, pause, prune) and what fits in repeat's
-- bound. Clues raised by a wave's reads are judged at the start of the next.
--
-- REPLAY. Run input {"replay": "<resource uri>"} names a verdict document,
-- {"model", "task", "verdicts": {qid: {clue key: P}}}; its P values are used
-- and Jev is asked only for the rest. {"offline": true} asks nobody, and a
-- clue with no stored P is unjudged, never accepted. aiq.walk_verdicts(run)
-- writes a finished run's verdicts in the same shape, so the first run of a
-- walk costs cents and every rerun nothing.
--
-- WHAT A RUN READS. Input {"channel": "<name>"} walks the `document` nodes of
-- that channel's resources, named by resource uri; {"nodes": "<entity_type>",
-- "prefix": "<key prefix>"} walks graph nodes, named by canonical key. The
-- question is {"question": {"id", "text"}}. Search is aiq.search over the
-- channel's chunks with the question embedded (the `q` step), or the order a
-- question node holds as walk_seed edges (provenance rank), or input
-- "search": [keys] for a short list.
-- ============================================================================

-- THE PARAMETERS (Sirsh, M-20261027-213302-a399): every number and wording the walk, its index, its decider, its
-- explanations and dreaming read is a row here, never a literal in code, and each row says what it controls, where
-- it is read and why it has the value it has, so the table also explains the algorithm:
--     select name, value, controls, why from aiq.parameters order by part, name;
-- The spec seeds the rows, set_by 'spec'. A later spec refreshes only rows still set by the spec, so a value tuned on
-- a deployment (set_by naming who, why saying on what evidence) survives an upgrade. One table for all of them,
-- rather than one per part, because they are one algorithm and are tuned against each other.
create table if not exists aiq.parameters (
    name       text primary key check (name ~ '^[a-z]+\.[a-z_]+$'),
    part       text not null check (part in ('index', 'search', 'walk', 'stack', 'decider', 'explain', 'dream')),
    value      jsonb not null,
    controls   text not null check (btrim(controls) <> ''),
    read_by    text not null check (btrim(read_by) <> ''),
    why        text not null check (btrim(why) <> ''),
    set_by     text not null default 'spec',
    updated_at timestamptz not null default now(),
    check (split_part(name, '.', 1) = part)
);
-- A table made before the question stack (REM-1245) has the old list of parts; converge it. Only when it lacks
-- 'stack': the ALTER takes an exclusive lock on a table every running walk reads, and an unconditional one on each
-- apply stalled ten live walks on 5801 until it was cancelled.
do $$
begin
    if not exists (select 1 from pg_constraint where conrelid = 'aiq.parameters'::regclass
                      and conname = 'parameters_part_check' and pg_get_constraintdef(oid) like '%''stack''%') then
        alter table aiq.parameters drop constraint if exists parameters_part_check;
        alter table aiq.parameters add constraint parameters_part_check
            check (part in ('index', 'search', 'walk', 'stack', 'decider', 'explain', 'dream'));
    end if;
end $$;
comment on table aiq.parameters is
    'The walk''s, its index''s, its decider''s, its explanations'' and dreaming''s parameters: value, what it controls, where it is read and why.';
alter table aiq.parameters enable row level security;
drop policy if exists parameters_readable on aiq.parameters;
create policy parameters_readable on aiq.parameters for select using (true);
grant select on aiq.parameters to authenticated;

insert into aiq.parameters as p (name, part, value, controls, read_by, why) values
 ('walk.waves', 'walk', '10', 'How many waves a walk runs before it stops.', 'aiq.walk_settings',
  'Ten waves of 50 is 500 reads, the budget the BEAM study and REM-1204''s crossover curves were measured at.'),
 ('walk.wave', 'walk', '50', 'Reads per wave; Jev judges the clues a wave raised before the next wave reads.', 'aiq.walk_settings',
  'The study''s waves2 arm: 50 reads keep a judge round near 48k tokens and let the walk change course ten times.'),
 ('walk.seeds', 'walk', '10', 'Search''s first reads, the ones that raise the first clues.', 'aiq.walk_settings',
  'The study''s explore10_all arm, chosen on 40 dev questions before the 150 test questions were walked.'),
 ('walk.per_wave', 'walk', '10', 'Search reads taken at the start of every later wave, before any clue is travelled.', 'aiq.walk_settings',
  'explore10_all: search keeps feeding the walk, so a walk is never worse off than search for long.'),
 ('walk.span', 'walk', '5', 'How far a next-message clue reaches either side of a read, within its sitting.', 'aiq.walk_settings, aiq.walk_graph_build',
  'Sirsh approved 5 (M-20261027-223456-e71c) on REM-1219''s test: 122 BEAM questions with stored verdicts, span 5 against 2 at 500 reads raised evidence share 0.897 to 0.931 (95% CI +0.008 to +0.066; 19 questions up, 8 down, sign p 0.052) and all-evidence questions 90 to 93; instruction following went 0.846 to 1.000 and no narrow type dropped. Missed evidence sat a few exchanges past evidence already read.'),
 ('walk.cap', 'walk', '100', 'A term is offered as a clue only when at most this many documents share it.', 'aiq.walk_settings, aiq.walk_state',
  'Set wide on Sirsh''s direction (M-20261028-074522-1623) until a sweep plots the walk across caps. At the old cap of 10 (REM-1208), on BEAM, 161 of 544 never-read evidence documents were reachable only through a wider tag, 153 of them in event-ordering or summarization questions. On REM-1204''s 156 buried test questions (deep order, span 2, 500 reads) the walk led search by +0.058 (95% CI +0.035 to +0.082) at cap 10, +0.049 at 30 and +0.050 at 100: no gain from widening, and a cost of about 0.01, inside the noise. Above the index''s fit cap (index.df_floor, index.df_share) the walk cap does nothing, because no wider term exists: on BEAM 1M that is 20 to 30 messages, so 100 acts as about 30 there and binds only on longer histories. query/38 pins the cap''s behaviour.'),
 ('walk.gate', 'walk', '0.5', 'The P at or above which a judged clue is accepted and may be travelled.', 'aiq.walk_settings, aiq.walk_why',
  'Jev''s P read as a probability: accept what is more likely than not to lead to the answer.'),
 ('walk.expand_all', 'walk', 'true', 'Whether every read raises clues, or only search''s seeds and what clues reach.', 'aiq.walk_settings',
  'The study''s _all arms beat seeds-only on BEAM test reach.'),
 ('walk.near', 'walk', '3', 'Nearest-in-meaning clues a read raises, from the index''s nearest neighbours.', 'aiq.walk_settings, aiq.walk_graph_build',
  'The study''s 3 nearest both ways; the index keeps index.nearest so this can be raised without re-indexing.'),
 ('walk.memory', 'walk', '0', 'How far a walk leans on stored verdicts: 0 asks afresh, 1 takes past verdicts whole.', 'aiq.walk_state',
  'Sirsh, M-20261027-115632-55e8: verdicts are stored, and reads are memoryless by default.'),
 ('walk.memory_as_of', 'walk', 'null', 'Which stored verdicts a walk with memory reads: those given before this run started (null), before a past run started (its id), or before a time.', 'aiq.walk_state',
  'Sirsh, M-20261028-134903-f73c: a rerun with memory read 86 verdicts its original never saw and differed in 451 of 500 reads; pinning the store to the original''s start keeps the memory it read.'),
 ('walk.order', 'walk', '"per_target"', 'Which accepted clue is travelled next: p, the highest P; or per_target, the highest P per unread document it leads to. (votes and wvotes, by how many open accepted clues agree on a target, exist only in core''s Python walk.)', 'aiq.walk_read',
  'REM-1219: votes gained 3 questions of 122 and lost none, sign p 0.25; not enough to change the default. per_target: under P alone the walk spent reads on wide bundles; ordering by P per unread read landed 28% more fresh evidence in REM-1240''s matched-budget replay, so the question stack (REM-1245) walks with it. V0''s default (walk spec 68c02f68). Part three''s published walks pin p.'),
 ('walk.stack', 'walk', 'true', 'Whether the walk keeps a question stack: the decider links reads to the questions they answer, splits the question into parts, closes what is answered, and judges each lead against the questions still open (aiq.walk_stack). Off, every lead is judged once against the question alone.', 'aiq.walk_state, aiq.walk_requests, aiq.walk_stack_requests, aiq.walk_read',
  'Sirsh, M-20261029-085819-f102 and M-20261029-085944-62bd: a memoryless walk keeps accepting echoes of what it has read (Jev''s AUC fell to 0.27 to 0.36 in later waves, REM-1240). The walkthrough''s published steps ran memoryless and pin it. V0 walks with the stack (walk spec 68c02f68, sally): a reader who starts a walk with the shipped defaults gets V0, and changes one row to see what it does. Part three''s published walks pin stack false, describe source and order p, which is what they ran.'),
 ('stack.link_floor', 'stack', '0.5', 'The P a read''s assessment must reach to link it to a question (a walk_answers edge), whatever its rank.', 'aiq.walk_stack_next',
  'A floor under the rank rule (sally''s guard on F10, adopted by bill, M-20261029-114953-bb74): rank alone links something even where nothing read is evidence. 0.5 since F14 (spec 1ac0e5dd, Sirsh 13:05Z), reversing 0.7: on the recognition run 0.5 and 0.7 give the same precision (19.0%), and 0.7 cost 1M:35 tr:0 its correct 10-read close and, in the rerun, any close at all. It also decides which lines close sees (F13).'),
 ('stack.link_share', 'stack', '0.02', 'A read links to a question only when its assessment ranks in the top max(stack.close_min_links, ceil(this share x the reads assessed against that question so far)), and clears stack.link_floor.', 'aiq.walk_stack_next',
  'F10, decided by bill (M-20261029-114822-4a81), Sirsh may overrule: at a fixed gate the links were mostly noise (evidence share of links 5.7% at 0.5, 6.6% at 0.7, against a 3.9% base), while by rank within the walk the top 2% were 19% evidence and the top 5% 14% (mike, REM-1240, on the gate''s run). Found on REM-1245''s ladder retest, where 232 of 443 other reads cleared 0.5.'),
 ('stack.close_min_links', 'stack', '2', 'A question is judged for closing only once at least this many reads are linked to it.', 'aiq.walk_stack_next',
  'sally''s guard on F10 (adopted by bill): links by rank are about 19% evidence, so one link is too thin to close on.'),
 ('stack.stale_waves', 'stack', '2', 'A part that gains no link for this many waves leaves the open list as stale: not answered, and its leads keep their P.', 'aiq.walk_stack_next, aiq.walk_state',
  'F9, decided by bill with sally''s guard (M-20261029-114953-bb74): on REM-1245''s ladder retest nothing ever closed and the four slots taken by wave 3 were held to the end.'),
 ('stack.max_displace', 'stack', '1', 'At most this many open parts a wave are displaced by a candidate with higher P; only a part with no link of its own can be.', 'aiq.walk_stack_next',
  'F11, decided by bill with sally''s guard: on the ladder retest ''ladder'' (P 0.78) and ''money'' (0.84) were judged parts after the slots were full and never opened.'),
 ('stack.close_gate', 'stack', '0.7', 'The P at or above which a question is answered by the reads linked to it, and leaves the open list.', 'aiq.walk_stack_next',
  'Above the link floor, so a question closes on more than one likely link. Not measured (REM-1244''s draft).'),
 ('stack.split_gate', 'stack', '0.5', 'The P at or above which a candidate part is opened as a question under its parent.', 'aiq.walk_stack_next',
  'The walk''s gate. Not measured.'),
 ('stack.max_open', 'stack', '4', 'At most this many parts are open at once (the root not counted). Every open question multiplies the leads judged.', 'aiq.walk_stack_next',
  'REM-1244''s draft: at 4 a wave judges at most 4 times today''s leads, under $0.10 of Jev for a 500-read walk.'),
 ('stack.candidates', 'stack', '3', 'How many candidate parts a wave that linked a read offers the decider: the terms the most reads linked to the root share (at least two), ties by specificity, not yet asked about.', 'aiq.walk_stack_next',
  'Few, because each is one judgement. The rarest term of each linked read was tried first and filled every slot with one aspect''s variants by wave 3 (REM-1245''s live ladder walk); walk.md §6 move 2. Not measured.'),
 ('stack.evidence_lines', 'stack', '12', 'How many lines the decider is shown when asked whether a question is answered: the lines assessed against it above stack.link_floor, highest P first, shown newest first (F13).', 'aiq.walk_stack_next',
  'About 12 lines of a user''s words fit the decider''s state at about 300 tokens a judgement. Since F13 the cap on every assessed line close sees, in either direction, highest P first. Not measured.'),
 ('stack.part_wording', 'stack', to_jsonb(text '%s (the part about ''%s'')'), 'How a candidate part is worded from its parent question and a term: format(wording, parent, term).', 'aiq.walk_stack_next',
  'No generative model is in the loop (Sirsh, M-20261029-105852-65d0), so a part is the parent narrowed to a term the evidence holds, and Jev chooses among them. A part written by a model comes through the walk''s input (parts), from a caller the walk asked.'),
 ('decider.request_bytes', 'decider', '24000', 'The most option text one Jev request carries; a round''s options are cut into requests of at most 60 options and at most this many bytes.', 'aiq.walk_requests, aiq.walk_stack_requests',
  'The workflow caps a task''s input at 64 KB (workflow.max_payload_bytes). Sixty options fit when a lead is described by one snippet of its source; described by three targets'' lines and what its source answered (walk.describe lines, walk.stack) sixty came to 83 KB and the request was refused (REM-1245''s first live stack walk). A task''s input holds the body twice (the matrix row, and the REST body rendered from it), so 40,000 bytes of options still came to 78 KB; 24,000 keeps two copies, the state and the keys under the cap.'),
 ('decider.task_assess', 'decider', to_jsonb(text 'For each option, a message from the user''s earlier conversations that the search has already read. Does it hold information needed to answer `question`, or part of it?'),
  'The question Jev answers for each new read and each open question: does this read answer it (REM-1245).', 'aiq.walk_stack_requests',
  'REM-1240''s recognition test, in its words: shown each read as ''the user wrote: "<line>"'', Jev picked out labelled evidence at a mean per-walk AUC of 0.745 [0.690, 0.799] over 53 walks of mixed types (oracle-scored). On REM-1245''s first two live stack walks (an event-ordering and a multi-session question, both all-on-topic) evidence and other reads scored alike (mean P 0.36 against 0.35, and 0.42 against 0.41).'),
 ('decider.task_state', 'decider', to_jsonb(text 'For each option, a message the user wrote, with the date it was said. Does this message answer `question`?'),
  'Asked of each candidate line of a leaf question, one line at a time: does this line answer it (walk spec 1d5f38d8 §6 move 4). A leaf closes on a line that clears stack.state_gate.', 'aiq.walk_stack_requests',
  'Jev is never asked whether a set of messages answers a question (Sirsh, 13:15Z): on the ten walks that holistic ask separated asks holding labelled evidence at AUC 0.622 and closed once in ten, wrongly. Jev judges one line well. Not measured in these words.'),
 ('decider.task_narrow', 'decider', to_jsonb(text 'Could a single message the user wrote answer `question` on its own, rather than a set, a count, a summary or a change across many messages?'),
  'Asked once of a walk''s root: is it narrow enough that one message could answer it. If not, the root is closed by no line, and the walk raises DECOMPOSITION_REQUIRED to the client (walk spec 1d5f38d8 §6 move 4, §12).', 'aiq.walk_stack_requests',
  'Narrowness is the board''s job: a broad root has no single answering message, so a line close on it would be the holistic question again. Wording not measured; the spec names no row, so this name is the build''s until mike''s spec names one.'),
 ('stack.narrow_gate', 'stack', '0.5', 'The P at or above which the walk''s root counts as narrow enough for one message to answer it; below it, the root is closed by no line and DECOMPOSITION_REQUIRED is raised.', 'aiq.walk_stack_next',
  'The walk''s own gate, read as a probability. Not measured.'),
 ('stack.state_gate', 'stack', 'null', 'The P at or above which one line is judged to answer a leaf question, which closes it; unset, the walk records each line''s verdict and closes nothing.', 'aiq.walk_stack_next',
  'Set on the calibration set registered in walk spec 4fed4425 §14 (F12): the lowest P whose closes are at least 90% correct, a correct close being one whose lines state BEAM''s reference answer, then tested once on a fresh draw. Unset until then.'),
 ('decider.task_split', 'decider', to_jsonb(text 'For each option, a narrower question. Is it a part of `question` that a complete answer needs?'),
  'The question Jev answers for each candidate part (REM-1245).', 'aiq.walk_stack_requests',
  'Not measured.'),
 ('walk.describe', 'walk', '"lines"', 'What a clue''s description shows the decider: source, the read message it comes out of; or targets, its kind, how many unread messages it leads to, and the rarest stored terms of up to 3 of them; or lines, what the user said in up to 3 of them (their stored lines, so nothing is read at walk time), how far each is from the source, and for a term how many messages hold it; or lines_nocount, the same with no count of messages, since a count can lift P on wide bundles (REM-1240). Neither source nor targets reads a target.', 'aiq.walk_state, aiq.walk_task, aiq.walk_describe_clue',
  'REM-1204: Jev, shown only a clue''s source, separates clues that lead to evidence at AUC 0.64 to 0.68; shown the targets'' stored terms, 0.69 to 0.75 (+0.06 [+0.03, +0.08] on 156 buried BEAM questions, +0.07 [+0.02, +0.14] on 41 indirect ones). Walked on the graded set (180 questions, span 5, cap 100), target terms beat source at read 50 on one-hop questions (+0.63 against +0.27 over search) and led search from split evidence up, where source lost. Source was the default until REM-1240 step 3. lines (REM-1240): on REM-1204''s A1 re-judge Jev given the targets'' own text separated them at 0.768, against 0.644 for the source and 0.634 to 0.641 for the question''s cosine to the same text; lines is that text, stored at ingest. Not yet walked. V0''s default (walk spec 68c02f68): REM-1240 step 3 passed lines against source on its registered bar, paired and between-source. Part three''s replayed walks pin source, the wording their verdicts were judged under.'),
 ('walk.near_miss', 'walk', 'null', 'Off, or {band, every}: every every-th travel takes the best rejected clue with P in [band, gate).', 'aiq.walk_read',
  'Off because no measurement shows it helps across questions: its only evidence is the walkthrough''s q19 (0 of 2 under the gate without it, 2 of 2 with {band 0.35, every 2}), REM-1207.'),
 ('decider.task_targets', 'decider', to_jsonb(text 'For each option, a lead to messages in the user''s earlier conversations that have not been read yet, described by the messages it leads to. Would following it likely reach information needed to answer `question`, or part of it?'),
  'The question Jev answers for every clue when walk.describe is targets. A verdict is kept with its wording, so verdicts given under one description never answer a clue described the other way.', 'aiq.walk_task',
  'REM-1204''s A1 re-judge and graded-set walks asked it in exactly these words.'),
 ('decider.task_lines', 'decider', to_jsonb(text 'For each option, a lead to messages in the user''s earlier conversations that have not been read yet, described by what the user said in them and where they sit. Would following it likely reach information needed to answer `question`, or part of it?'),
  'The question Jev answers for every clue when walk.describe is lines. A verdict is kept with its wording, so verdicts given under one description never answer a clue described another way.', 'aiq.walk_task',
  'REM-1240: task_targets'' wording, naming what lines shows. Not yet measured on its own.'),
 ('decider.task_lines_nocount', 'decider', to_jsonb(text 'For each option, a lead to messages in the user''s earlier conversations that have not been read yet, described by what the user said in some of them and where they sit. Would following it likely reach information needed to answer `question`, or part of it?'),
  'The question Jev answers for every clue when walk.describe is lines_nocount. Its own wording, so its verdicts are never mixed with lines''.', 'aiq.walk_task',
  'REM-1240: bill found P rising with bundle size under targets (median 0.23 at 1 target, 0.30 at 11+; flat 0.31 under source), which the walk''s P order spends reads on; lines_nocount tests whether stating the count does that. Not yet measured.'),
 ('search.hits', 'search', '2000', 'How many search hits a channel walk takes as its search order.', 'aiq.walk_start',
  'Enough to rank every document of a 1M BEAM conversation (about 1,100) by its best chunk.'),
 ('decider.task', 'decider', to_jsonb(text 'For each option, a lead into the user''s earlier messages that has not been read yet: a term the messages share, or the messages beside or close in meaning to one already read. Would following it likely reach information needed to answer `question`, or part of it?'),
  'The question Jev answers for every clue. A verdict is kept with this wording and is never mixed with another''s.', 'aiq.walk_task',
  'Ported from the BEAM study with REM-1200, where the generic wording beat one naming BEAM''s question types on 7 of 9 types.'),
 ('index.nearest', 'index', '10', 'Nearest-in-meaning documents the index links from each document.', 'percolate walk index (core walk/index.py)',
  'Ten keeps room above walk.near for a walk that asks for more, at about 10 edges a document.'),
 ('index.strategies', 'index', '["frequency"]', 'Which tagging strategies the index runs, in order: frequency (recurring word runs), entities (spaCy named entities), phrases (spaCy noun phrases). Each term records the strategies that found it.', 'percolate walk index (core walk/index.py)',
  'Layered on Sirsh''s direction (M-20261028-111716-14e1). Frequency alone stays the default because it needs no model and is what every measured walk ran; entities and phrases need percolate-core[tags]. On REM-1204''s 156 buried BEAM questions, spaCy entities joined the evidence''s 8.2 islands into 5.7 but moved a walk''s evidence share at 50 reads by only +0.014 (95% CI +0.003 to +0.027).'),
 ('index.min_df', 'index', '2', 'The LOWER bound of every strategy''s band: a tag must be held by at least this many documents. Small specific tags (a name in 3 messages) pass at any df_floor.', 'percolate walk index (core walk/terms.py limits_from)',
  'A tag one document holds links nothing.'),
 ('index.max_n', 'index', '3', 'The longest word run the frequency strategy keeps as a term.', 'percolate walk index (core walk/terms.py limits_from)',
  'The BEAM study''s tagger (REM-1144); its postings were checked equal on BEAM 1M:22.'),
 ('index.nest', 'index', '0.9', 'A shorter frequency term held almost only inside one longer kept term (this share of its documents) gives way to it.', 'percolate walk index (core walk/terms.py limits_from)',
  'C-value''s idea, as the BEAM study''s tagger had it (REM-1144).'),
 ('index.entity_labels', 'index', '["PERSON", "ORG", "GPE", "LOC", "FAC", "NORP", "PRODUCT", "EVENT", "WORK_OF_ART", "LANGUAGE", "DATE"]', 'The spaCy entity labels the entities strategy keeps.', 'percolate walk index (core walk/terms.py limits_from)',
  'People, places, organisations and dates (Sirsh, M-20261028-111716-14e1), and the other kinds spaCy''s English models name. REM-1204''s probe measured these labels without DATE, so DATE is unmeasured: a date such as today or monday can recur widely and link messages only by time; a deployment can drop it here.'),
 ('index.entity_df_floor', 'index', '100', 'The UPPER bound of the entities strategy''s band: an entity named in more than max(this, index.entity_df_share x documents) documents is dropped. Raising it admits wider entities and excludes none.', 'percolate walk index (core walk/terms.py limits_from)',
  'REM-1204''s probe: at 100 on BEAM 1M, entities reached 54% of buried evidence, an entity edge out of evidence led to evidence at 17 times chance (95% CI 11 to 26), and the evidence''s islands went 8.2 to 5.7; at 10 they reached 19% and joined almost none.'),
 ('index.entity_df_share', 'index', '0.02', 'The share of documents above which the entities strategy drops an entity, when it exceeds index.entity_df_floor.', 'percolate walk index (core walk/terms.py limits_from)',
  'The frequency strategy''s share, so the two scale alike on large sources. Not measured.'),
 ('index.phrase_df_floor', 'index', '50', 'The UPPER bound of the phrases strategy''s band: a noun phrase held by more than max(this, index.phrase_df_share x documents) documents is dropped. Raising it admits wider phrases and excludes none.', 'percolate walk index (core walk/terms.py limits_from)',
  'The frequency strategy''s floor, so a phrase and a word run are capped alike. Not measured.'),
 ('index.phrase_df_share', 'index', '0.02', 'The share of documents above which the phrases strategy drops a noun phrase, when it exceeds index.phrase_df_floor.', 'percolate walk index (core walk/terms.py limits_from)',
  'The frequency strategy''s share. Not measured.'),
 ('index.spacy_chars', 'index', '3000', 'How many characters of each document the entities and phrases strategies read.', 'percolate walk index (core walk/terms.py limits_from)',
  'REM-1204''s probe read the first 3,000; spaCy refuses a text over its max_length (1,000,000) and is slow well before, and uploaded files are long (james''s review of percolate-core#145).'),
 ('index.spacy_model', 'index', '"en_core_web_sm"', 'The spaCy model the entities and phrases strategies load.', 'percolate walk index (core walk/terms.py limits_from)',
  'The small English model REM-1204''s probe ran. Its speed on a large source is not measured.'),
 ('index.df_floor', 'index', '20', 'The UPPER bound of the frequency strategy''s band (index.min_df is the lower): the term fit keeps a term only when at most max(df_floor, df_share x documents) documents hold it. Raising it admits wider terms and excludes none.', 'percolate walk index (core walk/index.py, walk/terms.py)',
  'The term fitter''s 20 (REM-1201), kept on REM-1204''s parameter study: on its graded set of 180 questions, one walk per setting, a ceiling of 50 read 23 points less of the evidence than 20 at L1 by 100 reads (95% CI -40 to -10) and 100 read 20 less (-33 to -7); 100 read 13 less at L4 by 50 reads (-23 to -3); no level was clearly better above 20 (50 read 13 more at L2 by 50 reads, 0 to +27). It caps every walk_term posting, and so caps walk.cap from above. The cost it leaves: a name in 40 of a 1M history''s messages, 20 of them evidence (the trainer in BEAM''s buried questions), has no term at all, so that kind of reach belongs to the entities strategy and its own band.'),
 ('index.df_share', 'index', '0.02', 'With index.df_floor, the share of documents above which a term is too common to keep.', 'percolate walk index (core walk/index.py, walk/terms.py)',
  'Came in with the term fitter (REM-1201), not measured. It binds above 1,000 documents: about 30 on BEAM''s longer 1M histories and about 200 on 10M.'),
 ('explain.cold', 'explain', '0.05', 'A wave is cold when under this share of its expanded reads raised a new accepted clue.', 'aiq.walk_why, aiq.walk_audit (core walk/why.py)',
  'Not measured. Core walk/why.py credits REM-1194''s BEAM calibration, but that calibration binned cold at under 0.2; 0.05 is a stricter choice nobody tested.'),
 ('explain.near_miss', 'explain', '0.35', 'A rejected clue with P from this up to the gate is reported as a near miss.', 'aiq.walk_why (core walk/why.py)',
  'Not measured: a reporting band 0.15 under the gate, equal to the band REM-1207''s walkthrough travelled (0.35), so the audit and the walk agree on what a near miss is.')
on conflict (name) do update
   set value = excluded.value, controls = excluded.controls, read_by = excluded.read_by, why = excluded.why,
       updated_at = now()
 where p.set_by = 'spec';

-- One part's parameters as {name without the part: value}.
create or replace function aiq.parameters_of(p_part text) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
select coalesce(jsonb_object_agg(split_part(name, '.', 2), value), '{}'::jsonb) from aiq.parameters where part = p_part
$$;
-- readable by whoever may read aiq.parameters (every signed-in caller), so a walk's readers can call it as themselves
grant execute on function aiq.parameters_of(text) to authenticated;

-- One part's parameters, refusing when any it names is missing. aiq.parameters_of returns what is there, and a step
-- that read a missing row as null compared against null and silently did nothing: a stack step whose link_floor row
-- was absent would link no read and fail nothing (bill, REM-1245). A step that needs a parameter asks for it here.
create or replace function aiq.parameters_need(p_part text, p_names text[]) returns jsonb
language plpgsql stable set search_path = pg_catalog, public as $$
declare
    v       jsonb := aiq.parameters_of(p_part);
    missing text;
begin
    select string_agg(p_part || '.' || n, ', ' order by n) into missing
      from unnest(p_names) n where jsonb_typeof(v->n) is null or jsonb_typeof(v->n) = 'null';
    if missing is not null then
        raise no_data_found using message = format('aiq.parameters has no value for %s', missing),
            hint = 'the spec seeds every parameter a step reads; reload the extension''s parameters rather than run without them';
    end if;
    return v;
end;
$$;
grant execute on function aiq.parameters_need(text, text[]) to authenticated;

-- The wording a verdict is kept under (aiq.parameters decider.task). Verdicts given under another wording are
-- refused rather than mixed (percolate-core decide.py).
drop function if exists aiq.walk_task();
create or replace function aiq.walk_task(p_describe text default null) returns text
language plpgsql stable set search_path = pg_catalog, public as $$
begin
    -- walk.describe: source asks decider.task, targets decider.task_targets (REM-1204), lines decider.task_lines (REM-1240).
    if coalesce(p_describe, 'source') = 'source' then
        return (select value #>> '{}' from aiq.parameters where name = 'decider.task');
    elsif p_describe = 'targets' then
        return (select value #>> '{}' from aiq.parameters where name = 'decider.task_targets');
    elsif p_describe = 'lines' then
        return (select value #>> '{}' from aiq.parameters where name = 'decider.task_lines');
    elsif p_describe = 'lines_nocount' then
        return (select value #>> '{}' from aiq.parameters where name = 'decider.task_lines_nocount');
    end if;
    raise invalid_parameter_value using message = format('walk.describe is source, targets, lines or lines_nocount, not %s', p_describe);
end;
$$;

-- A clue's sign under walk.describe = targets: the rarest stored terms (fewest postings first) of up to 3 of its
-- targets, chosen by a hash of the clue key so the same clue always shows the same targets. Nothing is read.
create or replace function aiq.walk_signs(p_graph jsonb, p_key text, p_targets jsonb) returns text
language sql immutable set search_path = pg_catalog, public as $$
    select coalesce(string_agg(t.sign, ' | ' order by t.h), '(none)')
      from (select md5(p_key || ':' || (d.value #>> '{}')) as h,
                   coalesce((select string_agg(x.term, ', ' order by x.n, x.term)
                               from (select tm.value as term, jsonb_array_length(coalesce(p_graph->'post'->tm.value, '[]'::jsonb)) as n
                                       from jsonb_array_elements_text(coalesce(p_graph->'terms'->(d.value #>> '{}'), '[]'::jsonb)) tm
                                      order by 2, 1 limit 8) x), '(none)') as sign
              from jsonb_array_elements(p_targets) d
             order by 1 limit 3) t
$$;

-- A clue's description, as the decider reads it, under each walk.describe (REM-1240). aiq.walk_state calls it for the
-- clues the next round judges, and aiq.walk_clue_text for any clue a run raised, so a re-judge asks in the walk's own
-- words. p_text is the source's text (aiq.walk_texts); only source quotes it.
--   lines: up to 3 targets, chosen as aiq.walk_signs chooses them, each by what the user said in it (its stored
--   terms_text, or a node's summary) and how far it sits from the source: in the same sitting (the index's walk_next
--   provenance), by exchanges; in another, by days (said_at), when known. A term also says how many messages hold
--   it. lines_nocount is lines without any count. Nothing is read at walk time.
create or replace function aiq.walk_describe_clue(p_input jsonb, p_graph jsonb, p_describe text, p_key text,
                                                  p_kind text, p_x text, p_source text, p_targets jsonb,
                                                  p_text text default null)
returns text
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    n     int := jsonb_array_length(coalesce(p_targets, '[]'::jsonb));
    side  text := case p_kind when 'next' then 'just before and after a read one, in the same sitting'
                              else 'closest in meaning to a read one' end;
    lines text;
begin
    if coalesce(p_describe, 'source') = 'source' then
        if p_kind = 'term' then
            return format('the term ''%s'', which %s unread message(s) share with this read one: "%s"',
                          p_x, n, aiq.walk_snippet(p_text, p_x));
        end if;
        return format('%s: "%s"', case p_kind when 'next' then 'the messages just before and after this read one, in the same sitting'
                                            else 'the messages closest in meaning to this read one' end,
                      aiq.walk_snippet(p_text));
    elsif p_describe = 'targets' then
        if p_kind = 'term' then
            return format('the term ''%s'', shared by %s unread message(s). Their own key terms: %s',
                          p_x, n, aiq.walk_signs(p_graph, p_key, p_targets));
        end if;
        return format('%s unread message(s) %s. Their own key terms: %s', n, side, aiq.walk_signs(p_graph, p_key, p_targets));
    elsif p_describe not in ('lines', 'lines_nocount') then
        raise invalid_parameter_value using message = format('walk.describe is source, targets, lines or lines_nocount, not %s', p_describe);
    end if;
    with at as (
        select d.value #>> '{}' as doc, md5(p_key || ':' || (d.value #>> '{}')) as h
          from jsonb_array_elements(coalesce(p_targets, '[]'::jsonb)) d
         order by 2 limit 3
    ), doc as (
        select coalesce(r.uri, r.id::text) as doc, n.id as node, r.metadata->>'terms_text' as line,
               (r.metadata->>'said_at')::timestamptz as said_at
          from content.resources r join content.channels ch on ch.id = r.channel_id
          join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
         where p_input ? 'channel' and ch.name = p_input->>'channel'
           and coalesce(r.uri, r.id::text) in (select doc from at union select p_source)
        union all
        select k.key, n.id, n.summary, null
          from aiq.nodes n join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
         where p_input ? 'nodes' and n.entity_type = p_input->>'nodes'
           and k.key in (select doc from at union select p_source)
    ), meta as (
        -- A document's sitting and place are the index's walk_next provenance {sitting, pos}, pos being the edge's
        -- source's place: the next edge out of it, or one past the edge into it for a sitting's last.
        select d.doc, d.line, d.said_at,
               coalesce(o.provenance->>'sitting', i.provenance->>'sitting') as sitting,
               coalesce((o.provenance->>'pos')::int, (i.provenance->>'pos')::int + 1) as pos
          from doc d
          left join lateral (select e.provenance from aiq.edges e where e.src_id = d.node and e.relation = 'walk_next'
                                and e.valid_to is null limit 1) o on true
          left join lateral (select e.provenance from aiq.edges e where e.dst_id = d.node and e.relation = 'walk_next'
                                and e.valid_to is null limit 1) i on true
    )
    select string_agg(format('"%s"%s', aiq.walk_snippet(coalesce(t.line, at.doc)),
                             case when t.sitting is not null and t.sitting = s.sitting and t.pos is not null and s.pos is not null then
                                      format(' (same sitting, %s exchange(s) %s)', abs(t.pos - s.pos),
                                             case when t.pos < s.pos then 'earlier' else 'later' end)
                                  when t.said_at is not null and s.said_at is not null then
                                      case when t.said_at::date = s.said_at::date then ' (another sitting, the same day)'
                                           else format(' (another sitting, %s day(s) %s)',
                                                       abs(t.said_at::date - s.said_at::date),
                                                       case when t.said_at < s.said_at then 'earlier' else 'later' end) end
                                  else '' end), ' | ' order by at.h)
      into lines
      from at left join meta t on t.doc = at.doc left join meta s on s.doc = p_source;
    if p_describe = 'lines_nocount' then
        -- No count of messages: how wide a bundle is stays out of the decider's sight.
        if p_kind = 'term' then
            return format('the term ''%s''. What the user said in unread messages that hold it: %s', p_x, coalesce(lines, '(none)'));
        end if;
        return format('unread messages %s. What the user said in them: %s', side, coalesce(lines, '(none)'));
    end if;
    if p_kind = 'term' then
        return format('the term ''%s'', held by %s message(s) in all, %s of them unread. What the user said in them: %s',
                      p_x, jsonb_array_length(coalesce(p_graph->'post'->p_x, '[]'::jsonb)), n, coalesce(lines, '(none)'));
    end if;
    return format('%s unread message(s) %s. What the user said in them: %s', n, side, coalesce(lines, '(none)'));
end;
$$;

-- A walk's own rows, for whoever may read the run (REM-1245). Every reader of a walk -- the walk's own steps, a person
-- through PostgREST, a UI -- reads its run and task rows through these. `authenticated` holds no grant on the workflow
-- base tables (workflow-engine integration-rbac.sql §(a): reads are views, writes are functions), so a reader that
-- read them directly worked only as the database owner; cory's UI, signed in, got 'permission denied for table runs'.
-- The predicate is the engine's own, as workflow.plan_status asks it: an operator session, or a caller
-- workflow.may_access_run admits. Everything else a walk reads (documents, links, nodes) keeps the caller's own RLS.
create or replace function aiq.walk_run(p_run uuid)
returns setof workflow.runs
language sql stable security definer set search_path = pg_catalog, public as $$
    select r.* from workflow.runs r
     where r.id = p_run and (rbac.is_operator() or workflow.may_access_run(r.id, 'select'))
$$;
create or replace function aiq.walk_tasks(p_run uuid)
returns setof workflow.tasks
language sql stable security definer set search_path = pg_catalog, public as $$
    select t.* from workflow.tasks t
     where t.run_id = p_run and (rbac.is_operator() or workflow.may_access_run(p_run, 'select'))
$$;
-- Every walk the caller may read, for the list of walks (aiq.walk_runs).
create or replace function aiq.walk_runs_visible()
returns setof workflow.runs
language sql stable security definer set search_path = pg_catalog, public as $$
    select r.* from workflow.runs r
     where r.input ? 'question' and (rbac.is_operator() or workflow.may_access_run(r.id, 'select'))
$$;
revoke all on function aiq.walk_run(uuid), aiq.walk_tasks(uuid), aiq.walk_runs_visible() from public;
grant execute on function aiq.walk_run(uuid), aiq.walk_tasks(uuid), aiq.walk_runs_visible() to authenticated, worker;

-- The settings: the walk's parameters, under what a run's input asks for.
create or replace function aiq.walk_settings(p_input jsonb) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
select aiq.parameters_of('walk') || jsonb_build_object('hits', aiq.parameters_of('search')->'hits')
       || coalesce(p_input->'settings', '{}'::jsonb)
$$;

-- A run's scope, {node uuid: key}: the `document` nodes of a channel's resources by uri, or the nodes of an entity
-- type by canonical key.
create or replace function aiq.walk_keys(p_input jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    docs jsonb;
begin
    if p_input ? 'channel' then
        select jsonb_object_agg(n.id::text, coalesce(r.uri, r.id::text)) into docs
          from content.resources r
          join content.channels ch on ch.id = r.channel_id
          join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
         where ch.name = p_input->>'channel';
    elsif p_input ? 'nodes' then
        select jsonb_object_agg(n.id::text, k.key) into docs
          from aiq.nodes n
          join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
         where n.entity_type = p_input->>'nodes'
           and k.key like coalesce(p_input->>'prefix', '') || '%';
    else
        raise invalid_parameter_value using message = 'a walk reads a channel or a set of nodes',
            hint = 'start it with {"channel": "<name>"} or {"nodes": "<entity_type>", "prefix": "<key prefix>"}';
    end if;
    if docs is null then
        raise no_data_found using message = format('nothing to walk in %s', p_input - 'question' - 'settings'),
            hint = 'load the sample first; a channel walks its document nodes';
    end if;
    return docs;
end;
$$;

-- The text of some of a scope's documents, for the snippets a judge reads: a document's chunks in order, or a
-- node's summary. Fetched for the few a round needs rather than carried in the graph (4.4 MB on a BEAM channel).
create or replace function aiq.walk_texts(p_input jsonb, p_docs text[])
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select coalesce(jsonb_object_agg(d.doc, d.body), '{}'::jsonb) from (
        select coalesce(r.uri, r.id::text) as doc,
               coalesce((select string_agg(c.content, ' ' order by c.ordinal)
                           from content.resource_chunks c where c.resource_id = r.id), '') as body
          from content.resources r join content.channels ch on ch.id = r.channel_id
         where p_input ? 'channel' and ch.name = p_input->>'channel' and coalesce(r.uri, r.id::text) = any(p_docs)
        union all
        select k.key, coalesce(n.summary, k.key)
          from aiq.nodes n join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
         where p_input ? 'nodes' and n.entity_type = p_input->>'nodes' and k.key = any(p_docs)
    ) d
$$;

-- What a scope's graph is built from: its documents and the walk links out of them, each link by its ends, relation,
-- provenance and validity. Any change to one, a close backdated or a new row, moves a sum; as_of is the time after
-- which the graph no longer depends on the moment it is read. (48 ms on a BEAM channel, against 200 ms to build.)
create or replace function aiq.walk_graph_version(p_keys jsonb)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object(
               'docs', (select count(*) from jsonb_object_keys(p_keys)), 'edges', count(*), 'closed', count(e.valid_to),
               'links', sum(hashtext(e.src_id::text || e.dst_id::text || e.relation || e.provenance::text)::bigint),
               'from', sum(extract(epoch from e.valid_from)), 'to', sum(extract(epoch from e.valid_to)),
               'newest', max(e.created_at),
               'as_of', max(greatest(e.created_at, e.valid_from, coalesce(e.valid_to, e.valid_from))))
      from aiq.edges e
     where e.src_id = any (array(select k::uuid from jsonb_object_keys(p_keys) k))
       and e.relation in ('walk_term', 'walk_tagged', 'walk_next', 'walk_nearest')
$$;

-- Where a scope's graph is kept: one document per scope, the two settings the graph depends on, and the version of
-- its links. Links that change name a new document rather than rewrite one, because a resource's metadata is kept
-- from its first registration.
create or replace function aiq.walk_graph_uri(p_input jsonb, p_version jsonb)
returns text
language sql stable set search_path = pg_catalog, public as $$
    select 'walk-graph:' || md5(((p_input - 'question' - 'settings' - 'search' - 'replay' - 'control_of' - 'offline')
                                 || jsonb_build_object('span', aiq.walk_settings(p_input)->'span',
                                                       'near', aiq.walk_settings(p_input)->'near'))::text)
           || ':' || md5(p_version::text)
$$;

-- A scope's graph, read from its document when that was built from the links as they are, and built otherwise.
-- The graph is the same on every step of every run over the scope, and building it was most of a walk's cost
-- (76% of a BEAM walk's database time); a run as of a time before the links last changed builds its own.
create or replace function aiq.walk_graph(p_input jsonb, p_at timestamptz default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    v_at timestamptz := coalesce(p_at, now());
    v    jsonb := aiq.walk_graph_version(aiq.walk_keys(p_input));
    kept jsonb;
begin
    select res.metadata->'walk_graph' into kept
      from content.resources res
     where res.uri = aiq.walk_graph_uri(p_input, v)
     order by res.updated_at desc
     limit 1;
    if kept is not null and v_at >= (v->>'as_of')::timestamptz then
        return kept;
    end if;
    return aiq.walk_graph_build(p_input, v_at);
end;
$$;

-- Keep a scope's graph as a document in p_channel, so every walk over the scope reads it rather than building it.
-- Run it after loading the links, and again after changing them: a graph kept for links that have since changed
-- is never read, so a stale one costs a rebuild per step and is never wrong. The graph is the document's metadata;
-- its one chunk is '-', which indexes to no words, so search never finds it (as chunk text, a graph's terms put it
-- in the keyword ranking and moved the walk's own search order).
create or replace function aiq.walk_index(p_input jsonb, p_channel text default 'walk-graphs')
returns jsonb
language plpgsql volatile security invoker set search_path = pg_catalog, public as $$
declare
    v   jsonb := aiq.walk_graph_version(aiq.walk_keys(p_input));
    uri text := aiq.walk_graph_uri(p_input, v);
    g   jsonb;
begin
    -- the channel is made on first use, in the shared org where register_text looks for a channel a caller with no
    -- org names, so the first index on a fresh stack (percolate walk index keeps its graph) does not fail on it
    if not exists (select 1 from content.channels where name = p_channel) then
        insert into content.channels (name, kind, org_id, visibility)
        values (p_channel, 'manual', rbac.shared_org_id(), 'public');
    end if;
    g := aiq.walk_graph_build(p_input, greatest(now(), (v->>'as_of')::timestamptz));
    return content.register_text(p_channel, uri, '[{"content": "-"}]'::jsonb,
               'walk graph: ' || (p_input - 'question' - 'settings' - 'search' - 'replay' - 'control_of' - 'offline')::text, uri,
               null, jsonb_build_object('walk_graph', g, 'version', v))
           || jsonb_build_object('uri', uri, 'version', v);
end;
$$;

-- The graph a run walked (Sirsh, M-20261028-200720-890b). A walk's leads are read back from its graph, and an edge's
-- identity has no time in it: a re-index rewrites a walk_term's terms in place, and a tag renamed renames its leads.
-- So the start step records the kept graph document (aiq.walk_index) that holds the scope's links as they are when it
-- starts, and every later reading of the run (walk_state, so walk_clues, walk_why and the rest) takes the graph from
-- that document. Documents are never rewritten (changed links name a new one), so a pinned run reads what it walked.
-- A step is read-only and cannot write the document itself: a scope is pinned when it was indexed after its links
-- last changed, and a run started otherwise records no document and is read as of its start, as before.
create or replace function aiq.walk_run_graph(p_run uuid)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    r    workflow.runs;
    kept jsonb;
begin
    select * into r from aiq.walk_run(p_run);
    select res.metadata->'walk_graph' into kept
      from aiq.walk_tasks(p_run) tk
      join content.resources res on res.uri = tk.output->'result'->0->'state'->>'graph'
     where tk.run_id = p_run and tk.step_key = 'start' and tk.status = 'succeeded'
     order by res.updated_at desc
     limit 1;
    return coalesce(kept, aiq.walk_graph(r.input, r.created_at));
end;
$$;

-- One documents-and-links load for a run's scope, as the caller, as of p_at.
-- Returned as one jsonb so a walk's state is computed in one pass over it:
--   keys:  {node uuid: key}
--   terms: {key: [term, ...]}       post: {term: [key, ...]}
--   beside:{key: [key, ...]} within span either side, by walk_next
--   near:  {key: [key, ...]} the first `near` nearest, and who has it as one
-- A document's text is not in it: aiq.walk_texts fetches the few a round's snippets need.
create or replace function aiq.walk_graph_build(p_input jsonb, p_at timestamptz default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    s      jsonb := aiq.walk_settings(p_input);
    v_at   timestamptz := coalesce(p_at, now());
    docs   jsonb;
    terms  jsonb;
    post   jsonb;
    beside jsonb;
    near   jsonb;
begin
    docs := aiq.walk_keys(p_input);
    -- Terms: walk_term between two documents (provenance terms[]), and
    -- walk_tagged from a node to a tag node (the tag's summary is the term).
    with t as (
        select docs->>e.src_id::text as doc, x->>'term' as term, (x->>'rank')::int as rank,
               docs->>e.dst_id::text as other
          from aiq.edges e, jsonb_array_elements(e.provenance->'terms') x
         where e.relation = 'walk_term' and docs ? e.src_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
        union all
        select docs->>e.src_id::text, tn.summary, 0, null
          from aiq.edges e join aiq.nodes tn on tn.id = e.dst_id
         where e.relation = 'walk_tagged' and docs ? e.src_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    ), own as (
        select doc, term, min(rank) as rank from t group by doc, term
    ), holders as (
        select term, doc from t union select term, other from t where other is not null
        union
        -- a walk_tagged term's postings are every node tagged with it
        select tn.summary, docs->>e.src_id::text
          from aiq.edges e join aiq.nodes tn on tn.id = e.dst_id
         where e.relation = 'walk_tagged' and docs ? e.src_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    )
    select (select jsonb_object_agg(doc, ts) from (
                select doc, jsonb_agg(term order by rank, term) as ts from own group by doc) a),
           (select jsonb_object_agg(term, ds) from (
                select term, jsonb_agg(doc order by doc) as ds from holders where doc is not null group by term) b)
      into s, post;
    -- (s now holds the term lists; the settings are re-read below)
    terms := coalesce(s, '{}'::jsonb);
    s := aiq.walk_settings(p_input);
    -- Beside: the next chain, both ways, within span.
    with recursive nx as (
        select docs->>e.src_id::text as a, docs->>e.dst_id::text as b
          from aiq.edges e
         where e.relation = 'walk_next' and docs ? e.src_id::text and docs ? e.dst_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    ), both_ways as (
        select a, b from nx union select b, a from nx
    ), reach (origin, at, d) as (
        select a, b, 1 from both_ways
        union
        select r.origin, w.b, r.d + 1 from reach r join both_ways w on w.a = r.at
         where r.d < (s->>'span')::int and w.b <> r.origin
    )
    select jsonb_object_agg(origin, ks) into beside
      from (select origin, jsonb_agg(distinct at) as ks from reach group by origin) z;
    -- Nearest: the first `near` by rank, and the reverse lists.
    with nn as (
        select docs->>e.src_id::text as a, docs->>e.dst_id::text as b, (e.provenance->>'rank')::int as rank
          from aiq.edges e
         where e.relation = 'walk_nearest' and docs ? e.src_id::text and docs ? e.dst_id::text
           and (e.provenance->>'rank')::int < (s->>'near')::int
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    ), lists as (
        select a as doc, b as other, 0 as dir, rank from nn
        union all
        select b, a, 1, rank from nn
    )
    select jsonb_object_agg(doc, ks) into near
      from (select doc, jsonb_agg(other order by dir, rank, other) as ks from lists group by doc) z;
    return jsonb_build_object('keys', docs, 'terms', terms,
                              'post', coalesce(post, '{}'::jsonb), 'beside', coalesce(beside, '{}'::jsonb),
                              'near', coalesce(near, '{}'::jsonb));
end;
$$;

-- A clue's one-line description: what Jev reads instead of the documents.
create or replace function aiq.walk_snippet(p_text text, p_around text default null) returns text
language plpgsql immutable as $$
declare
    t text := regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g');
    i int;
begin
    t := btrim(t);
    if p_around is not null then
        i := strpos(lower(t), lower(p_around));
        if i > 81 then
            t := '…' || substr(t, i - 80);
        end if;
    end if;
    return left(t, 160);
end;
$$;

-- The verdicts the decider gave this run, one row a clue: the clue's key, its P, when it was answered and the model
-- that answered. Read from the judge step's tasks, which workflow retention prunes: aiq.walk_keep keeps them.
create or replace function aiq.walk_answers(p_run uuid)
returns table (key text, p real, at timestamptz, model text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select kk.value #>> '{}', (ch.output->'result'->'answers'->('c' || (kk.ordinality - 1))->>'noul')::real,
           ch.completed_at, ch.input->'item'->'body'->>'model'
      from aiq.walk_tasks(p_run) jt
      join aiq.walk_tasks(p_run) ch on ch.matrix_parent_id = jt.id and ch.status = 'succeeded'
      cross join lateral jsonb_array_elements(ch.input->'item'->'keys') with ordinality kk
     where jt.run_id = p_run and (jt.step_key like 'judge\_%' or jt.step_key like 'assess\_%' or jt.step_key like 'shape\_%')
       and ch.output->'result'->'answers'->('c' || (kk.ordinality - 1)) ? 'noul'
$$;

-- The walk so far, recomputed from the run's rows. Everything the reader's
-- functions return comes from here, so they cannot disagree with each other.
--
-- Returns {settings, question, order (search's order), waves: [{wave, reads:
-- [{doc, via, expanded}], travels, raised: [clue keys]}], clues: {key: {kind,
-- x, wave, source, targets, p}}, travelled: {key: wave}, reached, pending,
-- next: the clues the next wave would judge, with their descriptions, stop}.
create or replace function aiq.walk_state(p_run uuid)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    r        workflow.runs;
    inp      jsonb;
    s        jsonb;
    g        jsonb;
    q        jsonb;
    ord      jsonb;
    pmap     jsonb := '{}'::jsonb;
    rep      jsonb;
    logs     jsonb;
    w        jsonb;
    wn       int;
    clues    jsonb := '{}'::jsonb;
    reached  jsonb := '{}'::jsonb;   -- {key: true}
    travelled jsonb := '{}'::jsonb;  -- {clue key: wave}
    pending  jsonb := '[]'::jsonb;
    sources  jsonb := '[]'::jsonb;   -- the reads whose clues the next round judges
    nxt      jsonb := '{}'::jsonb;   -- clues the next round raises: {key: {kind, x, source, targets, text}}
    waves    jsonb := '[]'::jsonb;
    stop     jsonb;
    last     boolean;
    txt      jsonb;
    mem      real;
    asof     timestamptz;
    board    jsonb;
    lp       jsonb;
    serves   jsonb;
begin
    select * into r from aiq.walk_run(p_run);
    if not found then
        raise no_data_found using message = format('no run %s that you may read', p_run);
    end if;
    inp := r.input;
    s := aiq.walk_settings(inp);
    q := inp->'question';
    g := aiq.walk_run_graph(p_run);
    -- Search's order: the start step's record of it.
    select tk.output->'result'->0->'state'->'order' into ord
      from aiq.walk_tasks(p_run) tk where tk.run_id = p_run and tk.step_key = 'start' and tk.status = 'succeeded';
    -- P: the replay document, then every answer Jev gave this run.
    if inp ? 'replay' then
        select (string_agg(c.content, '' order by c.ordinal))::jsonb into rep
          from content.resources res join content.resource_chunks c on c.resource_id = res.id
         where res.id = (inp->>'replay')::uuid
         group by res.id;
        if rep is null then
            raise no_data_found using message = format('no replay document %s', inp->>'replay');
        end if;
        if rep->>'task' is distinct from aiq.walk_task(s->>'describe') then
            raise invalid_parameter_value using message = 'the replay was judged under another task wording',
                hint = 'a verdict belongs to its wording; walk again live, or replay a document made under this one';
        end if;
        pmap := coalesce(rep->'verdicts', '{}'::jsonb);
    end if;
    select pmap || coalesce(jsonb_object_agg(a.key, a.p), '{}'::jsonb) into pmap from aiq.walk_answers(p_run) a;
    -- Memory (settings.memory, 0 to 1, default 0): how far this run leans on the verdicts earlier runs kept for the
    -- same question under the same wording. At 0 they are not read. Above it, a clue judged before and now takes
    -- (1 - memory) * now + memory * the mean of before, and one judged only before takes the mean and is not asked.
    -- settings.memory_as_of moves the store's cutoff back: to a past run's start, given its id, or to a time. It never
    -- moves it past this run's own start, so the state of a finished run does not change as later runs keep verdicts.
    mem := coalesce((s->>'memory')::real, 0);
    asof := r.created_at;
    if mem > 0 and jsonb_typeof(s->'memory_as_of') = 'string' then
        if s->>'memory_as_of' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            select least(asof, x.created_at) into asof from aiq.walk_run((s->>'memory_as_of')::uuid) x;
            if not found then
                raise no_data_found using message = format('memory_as_of names no run %s that you may read', s->>'memory_as_of');
            end if;
        else
            asof := least(asof, (s->>'memory_as_of')::timestamptz);
        end if;
    end if;
    if mem > 0 and q ? 'node_id' then
        select coalesce(jsonb_object_agg(z.k, case when z.now_p is null then z.past
                                                   else (1 - mem) * z.now_p + mem * z.past end), '{}'::jsonb)
               || (select coalesce(jsonb_object_agg(n.key, n.value), '{}'::jsonb) from jsonb_each(pmap) n
                    where not exists (select 1 from aiq.walk_kept((q->>'node_id')::uuid, asof, aiq.walk_task(s->>'describe')) k
                                       where k.key = n.key))
          into pmap
          from (select k.key as k, avg(k.p)::real as past, (pmap->>k.key)::real as now_p
                  from aiq.walk_kept((q->>'node_id')::uuid, asof, aiq.walk_task(s->>'describe')) k
                 group by k.key) z;
    end if;
    -- The read steps' records, in wave order; wave 0 is the start step's.
    select jsonb_agg(x.rec order by (x.rec->>'wave')::int) into logs
      from (select tk.output->'result'->0->'state' as rec
              from aiq.walk_tasks(p_run) tk
             where tk.run_id = p_run and tk.status = 'succeeded'
               and (tk.step_key = 'start' or tk.step_key like 'read\_%')) x
     where x.rec ? 'wave';
    -- Each wave is applied as a whole: one jsonb merge per accumulator per wave. A merge per key copied the
    -- growing object every time, so a walk's state cost the square of its reads (1.3 s of 1.6 s at 500 reads).
    for w in select value from jsonb_array_elements(coalesce(logs, '[]'::jsonb)) loop
        wn := (w->>'wave')::int;
        -- Only the last wave's clues are still to be judged, and a clue's text is only read by its judge.
        last := wn = (logs->-1->>'wave')::int;
        txt := case when last then aiq.walk_texts(inp, array(select value->>'doc' from jsonb_array_elements(w->'reads')
                                                              where (value->>'expanded')::boolean)) end;
        -- The clues this wave's round judged: raised by the previous wave's expanded reads.
        if wn > 0 then
            clues := clues || coalesce((select jsonb_object_agg(key, (value - 'text')
                                                 || jsonb_build_object('wave', wn, 'p', pmap->key))
                                          from jsonb_each(nxt)), '{}'::jsonb);
        end if;
        -- Apply the wave's reads and travels.
        reached := reached || coalesce((select jsonb_object_agg(d, true) from (
                       select value->>'doc' as d from jsonb_array_elements(w->'reads')
                       union
                       select l #>> '{}' from jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)) tr,
                                              jsonb_array_elements(tr->'land') l) x), '{}'::jsonb);
        travelled := travelled || coalesce((select jsonb_object_agg(value->>'key', wn)
                                              from jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb))),
                                           '{}'::jsonb);
        pending := coalesce(w->'pending', '[]'::jsonb);
        waves := waves || jsonb_build_array(w || jsonb_build_object('raised',
                     (select coalesce(jsonb_agg(key order by key), '[]'::jsonb) from jsonb_each(nxt))));
        -- The next round's clues: out of this wave's expanded reads, never raised before, leading somewhere unread.
        -- A term's source is the first expanded read that carries it; its targets are the term's unread postings.
        with ex as (
            select value->>'doc' as src, o from jsonb_array_elements(w->'reads') with ordinality r(value, o)
             where (value->>'expanded')::boolean
        ), term as (
            select t, min(o) as o, count(*) as n
              from ex, jsonb_array_elements_text(coalesce(g->'terms'->src, '[]'::jsonb)) t
             where jsonb_array_length(coalesce(g->'post'->t, '[]'::jsonb)) <= (s->>'cap')::int
               and not clues ? ('term:' || t)
             group by t
        ), term_clue as (
            select 'term:' || term.t as k, term.t, ex.src,
                   -- a term raised by two reads had its targets re-aggregated distinct; kept so the record is unchanged
                   case when term.n > 1 then (select jsonb_agg(distinct value) from jsonb_array_elements(g->'post'->term.t)
                                               where not reached ? (value #>> '{}'))
                        else (select jsonb_agg(value order by value #>> '{}') from jsonb_array_elements(g->'post'->term.t)
                               where not reached ? (value #>> '{}')) end as tg
              from term join ex on ex.o = term.o
        ), side_clue as (
            select kind || ':' || ex.src as k, kind, ex.src,
                   (select jsonb_agg(distinct value)
                      from jsonb_array_elements(coalesce(g->(case kind when 'next' then 'beside' else 'near' end)->ex.src,
                                                         '[]'::jsonb))
                     where not reached ? (value #>> '{}') and value #>> '{}' <> ex.src) as tg
              from ex, unnest(array['next', 'near']) kind
             where not clues ? (kind || ':' || ex.src)
        )
        select coalesce(jsonb_object_agg(k, c), '{}'::jsonb) into nxt from (
            select k, jsonb_build_object(
                       'kind', 'term', 'x', t, 'source', src, 'targets', tg,
                       'text', case when last then aiq.walk_describe_clue(inp, g, s->>'describe', k, 'term', t, src, tg,
                                                                          txt->>src) end) as c
              from term_clue where tg is not null
            union all
            select distinct on (k) k, jsonb_build_object(
                       'kind', kind, 'x', src, 'source', src, 'targets', tg,
                       'text', case when last then aiq.walk_describe_clue(inp, g, s->>'describe', k, kind, src, src, tg,
                                                                          txt->>src) end)
              from side_clue where tg is not null
        ) z;
        stop := w->'stop';
    end loop;
    -- The question stack (walk.stack, REM-1245): the board after the last recorded stack step. A lead's P is then the
    -- highest the decider gave it against any question not answered (verdict keys L|<question>|<lead>), and the
    -- question it serves is that one, so a lead toward a question already answered falls away; a part closed stale or
    -- displaced was not answered, and its leads keep their P (F9, F11). The raw verdicts,
    -- every kind, stay in `answers` for walk_verdicts and the stack's own steps.
    if coalesce((s->>'stack')::boolean, false) then
        -- the board: every recorded wave's moves folded onto the initial one (walk-stack.sql)
        select b into board from aiq.walk_stack_boards(p_run) b order by (b->>'iteration')::int desc limit 1;
        select coalesce(jsonb_object_agg(z.key, z.p), '{}'::jsonb), coalesce(jsonb_object_agg(z.key, z.q), '{}'::jsonb)
          into lp, serves
          from (select distinct on (c.key) c.key, (pmap->>('L|' || o.q || '|' || c.key))::real as p, o.q
                  from (select key from jsonb_each(clues) union select key from jsonb_each(nxt)) c,
                       -- every question not answered: open, or closed stale or displaced, whose leads keep their P
                       (select key as q from jsonb_each(board->'questions') where value->>'state' <> 'answered') o
                 where pmap ? ('L|' || o.q || '|' || c.key)
                 order by c.key, 2 desc, o.q) z;
        return jsonb_build_object('settings', s, 'question', q, 'order', coalesce(ord, '[]'::jsonb),
                                  'waves', waves, 'clues', clues, 'travelled', travelled, 'reached', reached,
                                  'pending', pending, 'next', nxt, 'pmap_size', (select count(*) from jsonb_object_keys(pmap)),
                                  'p', lp, 'serves', serves, 'answers', pmap, 'board', board, 'stop', stop,
                                  'replay', inp->'replay', 'offline', coalesce(inp->'offline', 'false'));
    end if;
    return jsonb_build_object('settings', s, 'question', q, 'order', coalesce(ord, '[]'::jsonb),
                              'waves', waves, 'clues', clues, 'travelled', travelled, 'reached', reached,
                              'pending', pending, 'next', nxt, 'pmap_size', (select count(*) from jsonb_object_keys(pmap)),
                              'p', pmap, 'stop', stop, 'replay', inp->'replay', 'offline', coalesce(inp->'offline', 'false'));
end;
$$;

-- Whether the question needs embedding: only a channel walk with no stored
-- order searches by meaning. A graph walk, or one given its order, skips the
-- embed step, so a walk over a graph runs with no worker at all.
create or replace function aiq.walk_needs_vector(p_run uuid) returns boolean
language sql stable security invoker set search_path = pg_catalog, public as $$
    select coalesce((select input ? 'channel' and not input ? 'search' from aiq.walk_run(p_run)), false)
$$;

-- The start step: search's order, and its first `seeds` reads as wave 0.
create or replace function aiq.walk_start(p_run uuid, p_vector vector default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    r     workflow.runs;
    inp   jsonb;
    s     jsonb;
    g     jsonb;
    ord   jsonb;
    seeds jsonb;
begin
    select * into r from aiq.walk_run(p_run);
    inp := r.input;
    -- The question is {node_id, text} and nothing else, so a walk never carries its answer key: evaluation passes the
    -- labelled nodes to aiq.walk_coverage and aiq.walk_why from outside the run (REM-1231).
    if exists (select 1 from jsonb_object_keys(coalesce(inp->'question', '{}')) k where k not in ('node_id', 'text')) then
        raise invalid_parameter_value using message = format('a walk''s question is {node_id, text}; this one also carries %s',
                (select string_agg(k, ', ' order by k) from jsonb_object_keys(inp->'question') k where k not in ('node_id', 'text'))),
            hint = 'start it with {"question": {"node_id": ..., "text": ...}}; pass any labels to the evaluation functions';
    end if;
    s := aiq.walk_settings(inp);
    g := aiq.walk_graph(inp, r.created_at);
    -- A replay is checked here, at the first step, so a wrong one fails the walk once rather than every retry of a
    -- matrix expansion: walk_state raises if it is missing or was judged under another wording.
    if inp ? 'replay' then
        perform aiq.walk_state(p_run);
    end if;
    if inp ? 'search' then
        ord := inp->'search';
    elsif p_vector is not null and inp ? 'channel' then
        -- a hit stands for its document, at the rank of its best chunk
        select jsonb_agg(doc order by first_rank) into ord
          from (select coalesce(res.uri, res.id::text) as doc, min(h.rn) as first_rank
                  from (select chunk_id, row_number() over () as rn
                          from aiq.search('chunks', inp->'question'->>'text', p_vector, null, (s->>'hits')::int, 60,
                                          jsonb_build_object('channel', inp->>'channel'))) h
                  join content.resource_chunks c on c.id = h.chunk_id
                  join content.resources res on res.id = c.resource_id
                  join content.channels ch on ch.id = res.channel_id and ch.name = inp->>'channel'
                 group by 1) z;
    else
        -- a question node's stored order: walk_seed edges with provenance rank
        select jsonb_agg(k2.key order by (e.provenance->>'rank')::int) into ord
          from aiq.node_keys k1
          join aiq.edges e on e.src_id = k1.node_id and e.relation = 'walk_seed'
          join aiq.node_keys k2 on k2.node_id = e.dst_id and k2.kind = 'canonical'
         where k1.node_id = (inp->'question'->>'node_id')::uuid and k1.kind = 'canonical';
    end if;
    if ord is null or jsonb_array_length(ord) = 0 then
        raise no_data_found using message = format('search returned nothing for %s', coalesce(inp->'question'->>'node_id', inp->'question'->>'text')),
            hint = 'a channel walk needs the question embedded (the q step); a graph walk needs walk_seed edges or "search"';
    end if;
    select jsonb_agg(jsonb_build_object('doc', value #>> '{}', 'via', 'search', 'expanded', true) order by ordinality)
      into seeds
      from jsonb_array_elements(ord) with ordinality
     where ordinality <= (s->>'seeds')::int
       and (value #>> '{}') in (select k.v from jsonb_each_text(g->'keys') k(n, v));
    return jsonb_build_object('wave', 0, 'order', ord, 'si', (s->>'seeds')::int, 'reads', seeds,
                              'travels', '[]'::jsonb, 'pending', '[]'::jsonb,
                              'graph', (select res.uri from content.resources res
                                         where res.uri = aiq.walk_graph_uri(inp, aiq.walk_graph_version(aiq.walk_keys(inp)))
                                         limit 1));
end;
$$;

-- The judge step's rows: one Jev request for each 60 clues this round raises
-- that the replay lacks. None when offline, or when the replay holds them all.
-- Under walk.stack, every live lead against every open question it has not been judged against (REM-1245); each wave
-- first runs the stack's own steps (assess, shape, stack: walk-stack.sql), which do nothing when the walk keeps none.
create or replace function aiq.walk_requests(p_run uuid, p_decider text default 'jev')
returns table (chunk int, keys jsonb, body jsonb)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    st  jsonb := aiq.walk_state(p_run);
    d   claims.deciders;
begin
    if (st->>'offline')::boolean then
        return;
    end if;
    select * into d from claims.deciders where name = p_decider;
    if not found then
        raise no_data_found using message = format('no decider named %s is configured', p_decider);
    end if;
    if coalesce((st->'settings'->>'stack')::boolean, false) then
        -- The question stack (REM-1245, walk.md §7): each lead this round raised, against every question open now.
        -- One request per open question, the question as Jev's `question`, so a lead is judged against what is still
        -- to be found rather than the root alone. A lead is judged once, when it is raised, and its P stays fixed
        -- (Sirsh, F3); a question opened later is served by the leads raised after it. A lead's description says what
        -- its source was found to answer, so the decider knows which reads were evidence (REM-1240: a term lead out
        -- of an evidence read is about 12 times as likely to be right); out of a read that answered nothing, it says
        -- nothing more.
        return query
        with g as (select aiq.walk_run_graph(p_run) as g),
        inp as (select input from aiq.walk_run(p_run)),
        live as (
            select key, value from jsonb_each(st->'next')
        ), todo as (
            select l.key, l.value as c, o.q
              from live l, jsonb_array_elements_text(st->'board'->'open') o(q)
             where not (st->'answers') ? ('L|' || o.q || '|' || l.key)
        ), srcs as (
            select aiq.walk_texts((select input from inp), array(select distinct c->>'source' from todo)) as t
        ), said as (
            -- what each source was linked to, best first: its line in the lead's description
            select e->>'doc' as doc, string_agg(format('''%s''', st->'board'->'questions'->(e->>'q')->>'text'), ' and '
                                                order by (e->>'p')::real desc) as qs
              from jsonb_array_elements(st->'board'->'evidence') e group by 1
        ), described as (
            select t.q, 'L|' || t.q || '|' || t.key as key,
                   coalesce(case when t.c ? 'text' and t.c->>'text' is not null then t.c->>'text' end,
                            aiq.walk_describe_clue((select input from inp), g.g, st->'settings'->>'describe', t.key,
                                                   t.c->>'kind', t.c->>'x', t.c->>'source',
                                                   (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(t.c->'targets') x
                                                     where not (st->'reached') ? (x #>> '{}')),
                                                   srcs.t->>(t.c->>'source')))
                   || case when sd.qs is not null then ' It comes out of a message found to answer: ' || sd.qs || '.'
                           else '' end as text
              from todo t cross join g cross join srcs left join said sd on sd.doc = t.c->>'source'
        ), numbered as (
            -- a request holds at most 60 options and decider.request_bytes of their text
            select q, key, text, row_number() over (partition by q order by key) - 1 as j,
                   sum(octet_length(text) + octet_length(key) + 64) over (partition by q order by key) as cum
              from described
        ), cut as (
            select n.*, (n.j / 60) as by_count,
                   (n.cum / (select (value #>> '{}')::int from aiq.parameters where name = 'decider.request_bytes'))::int as by_bytes
              from numbered n
        ), chunks as (
            select q, key, text, dense_rank() over (order by q, by_bytes, by_count) - 1 as chunk,
                   (row_number() over (partition by q, by_bytes, by_count order by key) - 1)::int as jj
              from cut
        )
        select c.chunk::int,
               jsonb_agg(c.key order by c.jj),
               jsonb_build_object('model', d.model,
                                  'state', jsonb_build_object('question', st->'board'->'questions'->(min(c.q))->>'text',
                                                              'task', aiq.walk_task(st->'settings'->>'describe')),
                                  'questions', jsonb_object_agg('c' || c.jj,
                                      jsonb_build_object('type', 'noul', 'instructions', c.text)))
          from chunks c
         group by c.chunk
         order by c.chunk;
        return;
    end if;
    return query
    with todo as (
        select key, value->>'text' as text, row_number() over (order by key) - 1 as i
          from jsonb_each(st->'next')
         where not (st->'p') ? key
    ), chunks as (
        select (i / 60)::int as chunk, key, text, (i % 60)::int as j from todo
    )
    select c.chunk,
           jsonb_agg(c.key order by c.j),
           jsonb_build_object('model', d.model,
                              'state', jsonb_build_object('question', st->'question'->>'text',
                                                          'task', aiq.walk_task(st->'settings'->>'describe')),
                              'questions', jsonb_object_agg('c' || c.j,
                                  jsonb_build_object('type', 'noul', 'instructions', c.text)))
      from chunks c
     group by c.chunk
     order by c.chunk;
end;
$$;

-- The read step: gate this round's clues, then travel accepted clues best
-- first, reading what they reach, until the wave holds its share of reads.
-- Search fills in when no accepted clue is left; with nothing left at all the
-- wave is dry and the walk stops.
create or replace function aiq.walk_read(p_run uuid)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    st      jsonb := aiq.walk_state(p_run);
    s       jsonb := st->'settings';
    wn      int := jsonb_array_length(st->'waves');   -- waves so far, counting wave 0
    target  int;
    ord     jsonb := st->'order';
    si      int := coalesce((st->'waves'->-1->>'si')::int, 0);
    reached jsonb := st->'reached';
    open_   jsonb := '{}'::jsonb;   -- {key: {p, targets}}
    -- Near misses (REM-1207), off unless settings.near_miss = {band, every}: rejected clues with P in [band, gate),
    -- of which every `every`-th travel takes the best. A fixed rotation rather than the study's coin, so a replay
    -- reads the same documents in the same order on any engine.
    nm      jsonb := s->'near_miss';
    misses  jsonb := '{}'::jsonb;   -- {key: {p, targets}}
    travel  int := (select count(*) from jsonb_array_elements(st->'waves') w,
                           jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)))::int;
    miss    boolean;
    reads   jsonb := '[]'::jsonb;
    travels jsonb := '[]'::jsonb;
    pending jsonb := st->'pending';
    best    text;
    bp      real;
    land    jsonb;
    doc     text;
    n       int := 0;
    failed  int;
    asked   int;
    why     text;
begin
    if wn = 0 then
        raise invalid_parameter_value using message = 'the walk has not started: no seeds recorded';
    end if;
    -- A Jev request that failed leaves its clues unjudged, and a walk that read on without them would end succeeded
    -- with a result it does not have (REM-1225: an empty account cost 244 walks 4,579 of 10,112 requests, and all
    -- 244 ended succeeded). So a failed request stops the walk, here, before it reads past the gap.
    -- A request is failed only once its retries are spent, or at once when the provider says retrying will not help
    -- (workflow.fail_task puts a retryable failure back to ready), so one timeout does not stop a walk.
    select count(*) filter (where t.status = 'failed'), count(*),
           (array_agg(t.error->>'error' order by t.updated_at) filter (where t.status = 'failed'))[1]
      into failed, asked, why
      from aiq.walk_tasks(p_run) t
     where t.run_id = p_run and (t.step_key like 'judge\_%' or t.step_key like 'assess\_%' or t.step_key like 'shape\_%')
       and t.matrix_parent_id is not null;
    if failed > 0 then
        raise exception '% of the % Jev requests in this walk failed, so their clues were never judged', failed, asked
            using hint = 'the walk stops rather than read on without them; the first error: ' || coalesce(why, 'none recorded');
    end if;
    if coalesce(s->>'order', 'p') not in ('p', 'per_target') then
        raise invalid_parameter_value using message = format('walk.order is p or per_target here, not %s', s->>'order'),
            hint = 'votes and wvotes exist only in core''s Python walk';
    end if;
    -- The question stack (REM-1245): with the root answered there is nothing left to look for, and the walk stops.
    if st->'board'->'questions'->'root'->>'state' = 'answered' then
        return jsonb_build_object('wave', wn, 'si', si, 'reads', '[]'::jsonb, 'travels', '[]'::jsonb, 'pending', '[]'::jsonb,
                                  'judged', 0, 'unjudged', 0, 'dry', true,
                                  'stop', jsonb_build_object('reason', 'answered', 'wave', wn,
                                                             'closed_at', st->'board'->'questions'->'root'->'closed_wave'));
    end if;
    -- Every accepted clue still leading somewhere unread: earlier waves' not
    -- yet travelled, and this round's.
    -- (each built in one aggregate: a merge per key copies the growing object every time)
    select coalesce(jsonb_object_agg(c.key, jsonb_build_object('p', (st->'p'->>c.key)::real, 'targets', c.value->'targets')),
                    '{}'::jsonb) into open_
      from (select key, value from jsonb_each(st->'clues') where not (st->'travelled') ? key
            union all
            select key, value from jsonb_each(st->'next')) c
     where (st->'p'->>c.key)::real >= (s->>'gate')::real;
    if jsonb_typeof(nm) = 'object' then
        select coalesce(jsonb_object_agg(c.key, jsonb_build_object('p', (st->'p'->>c.key)::real,
                                                                  'targets', coalesce(st->'clues'->c.key->'targets',
                                                                                      st->'next'->c.key->'targets'))),
                        '{}'::jsonb) into misses
          from (select key from jsonb_each(st->'clues') union select key from jsonb_each(st->'next')) c
         where (st->'p'->>c.key)::real >= (nm->>'band')::real and (st->'p'->>c.key)::real < (s->>'gate')::real
           and not (st->'travelled') ? c.key;
    end if;
    -- Cold (walk.md §8, Sirsh F1), under walk.stack: this round accepted no lead it raised, and no accepted lead is
    -- still open. Nothing the decider believes in is left to follow, so the walk stops rather than read on in search's
    -- order: REM-1211's certificate, now a stop. (Read literally, "no newly accepted lead" would also stop a walk
    -- with accepted leads still unopened, abandoning them; it waits for those.)
    if coalesce((s->>'stack')::boolean, false) and open_ = '{}'::jsonb
       and not exists (select 1 from jsonb_each(st->'next') x where (st->'p'->>x.key)::real >= (s->>'gate')::real) then
        return jsonb_build_object('wave', wn, 'si', si, 'reads', '[]'::jsonb, 'travels', '[]'::jsonb, 'pending', pending,
                                  'judged', (select count(*) from jsonb_each(st->'next') x where (st->'answers') ? x.key),
                                  'unjudged', 0, 'dry', true,
                                  'stop', jsonb_build_object('reason', 'cold', 'wave', wn,
                                                             'raised', (select count(*) from jsonb_each(st->'next'))));
    end if;
    -- The wave's size: cumulative reads reach wave * size (wave 0's seeds count toward wave 1).
    target := wn * (s->>'wave')::int
              - (select count(*) from jsonb_array_elements(st->'waves') w, jsonb_array_elements(w->'reads'))::int;
    -- Search first, per_wave of it, from the second wave on.
    if wn > 1 then
        while n < least((s->>'per_wave')::int, target) and si < jsonb_array_length(ord) loop
            doc := ord->>si;
            si := si + 1;
            if not reached ? doc then
                reached := reached || jsonb_build_object(doc, true);
                reads := reads || jsonb_build_array(jsonb_build_object('doc', doc, 'via', 'search',
                                                    'expanded', (s->>'expand_all')::boolean));
                n := n + 1;
            end if;
        end loop;
    end if;
    while n < target loop
        if jsonb_array_length(pending) > 0 then
            doc := pending->>0;
            pending := pending - 0;
            reads := reads || jsonb_build_array(jsonb_build_object('doc', doc, 'via', best, 'expanded', true));
            n := n + 1;
            continue;
        end if;
        -- the best accepted clue that still leads somewhere unread, ties by key; on every `every`-th travel the
        -- best near miss instead, when one leads somewhere unread
        best := null;
        miss := false;
        if jsonb_typeof(nm) = 'object' and travel % (nm->>'every')::int = (nm->>'every')::int - 1 then
            select o.key, (o.value->>'p')::real into best, bp
              from jsonb_each(misses) o
             where exists (select 1 from jsonb_array_elements(o.value->'targets') t where not reached ? (t #>> '{}'))
             order by (o.value->>'p')::real desc, o.key
             limit 1;
            miss := best is not null;
        end if;
        if not miss then
            -- walk.order: p, the highest P; per_target, the highest P per document it would still read (REM-1240)
            select o.key, (o.value->>'p')::real into best, bp
              from jsonb_each(open_) o
              cross join lateral (select count(*) as n from jsonb_array_elements(o.value->'targets') t
                                   where not reached ? (t #>> '{}')) u
             where u.n > 0
             order by case when s->>'order' = 'per_target' then (o.value->>'p')::real / u.n
                           else (o.value->>'p')::real end desc, o.key
             limit 1;
        end if;
        if best is not null then
            select coalesce(jsonb_agg(t order by ord_), '[]'::jsonb) into land
              from jsonb_array_elements(case when miss then misses else open_ end->best->'targets')
                   with ordinality x(t, ord_)
             where not reached ? (t #>> '{}');
            open_ := open_ - best;
            misses := misses - best;
            travel := travel + 1;
            for doc in select value #>> '{}' from jsonb_array_elements(land) loop
                reached := reached || jsonb_build_object(doc, true);
            end loop;
            pending := pending || land;
            travels := travels || jsonb_build_array(jsonb_build_object('key', best, 'p', round(bp::numeric, 3),
                                                                       'land', land)
                                                    || case when st->'serves' ? best
                                                            then jsonb_build_object('serves', st->'serves'->>best)
                                                            else '{}'::jsonb end
                                                    || case when miss then '{"near_miss": true}'::jsonb
                                                            else '{}'::jsonb end);
            continue;
        end if;
        -- nothing accepted is left: search fills the wave. With search spent too the wave ends here, but it is
        -- not dry while it read anything: those reads' clues are raised and judged at the next wave's start, and
        -- only a wave that reads nothing at all has nothing left to judge (james, REM-1205: a stop declared before
        -- the last reads were judged looked like a certificate and was not one).
        if si >= jsonb_array_length(ord) then
            exit;
        end if;
        doc := ord->>si;
        si := si + 1;
        if not reached ? doc then
            reached := reached || jsonb_build_object(doc, true);
            reads := reads || jsonb_build_array(jsonb_build_object('doc', doc, 'via', 'search',
                                                'expanded', (s->>'expand_all')::boolean));
            n := n + 1;
        end if;
    end loop;
    return jsonb_build_object('wave', wn, 'si', si, 'reads', reads, 'travels', travels, 'pending', pending,
                              'judged', (select count(*) from jsonb_each(st->'next') x where (st->'p') ? x.key),
                              'unjudged', (select count(*) from jsonb_each(st->'next') x where not (st->'p') ? x.key),
                              'dry', n = 0,
                              'stop', case when n = 0 then jsonb_build_object('reason', 'dry', 'wave', wn) end);
end;
$$;

-- ---------------------------------------------------------------- what a reader queries
-- Each view comes in two forms: one over a run, and one over a state already built (aiq.walk_state_*), so a
-- query that reads several views of one run builds its state once rather than once per view.
create or replace function aiq.walk_state_reads(p_state jsonb)
returns table (wave int, ord int, doc text, via text, expanded boolean)
language sql immutable security invoker set search_path = pg_catalog, public as $$
    select (w->>'wave')::int, r.ordinality::int, r.value->>'doc', r.value->>'via', (r.value->>'expanded')::boolean
      from jsonb_array_elements(p_state->'waves') w,
           jsonb_array_elements(w->'reads') with ordinality r
     order by 1, 2
$$;

create or replace function aiq.walk_reads(p_run uuid)
returns table (wave int, ord int, doc text, via text, expanded boolean)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from aiq.walk_state_reads(aiq.walk_state(p_run))
$$;

-- Search's own order for the run's question: what plain search would have
-- read, rank by rank, for setting a walk beside it read for read.
create or replace function aiq.walk_search_order(p_run uuid)
returns table (rank int, doc text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select o.ordinality::int, o.value #>> '{}'
      from aiq.walk_tasks(p_run) tk, jsonb_array_elements(tk.output->'result'->0->'state'->'order') with ordinality o
     where tk.run_id = p_run and tk.step_key = 'start' and tk.status = 'succeeded'
     order by 1
$$;

-- serves: under walk.stack, the open question the lead's P was given against (REM-1245); null otherwise.
drop function if exists aiq.walk_clues(uuid);
drop function if exists aiq.walk_state_clues(jsonb);
create or replace function aiq.walk_state_clues(p_state jsonb)
returns table (key text, kind text, wave int, source text, targets text[], p real, decision text, state text,
               travelled_wave int, serves text)
language sql immutable security invoker set search_path = pg_catalog, public as $$
    with st as (select p_state as st)
    select c.key, c.value->>'kind', (c.value->>'wave')::int, c.value->>'source',
           array(select jsonb_array_elements_text(c.value->'targets')),
           (st->'p'->>c.key)::real,
           case when st->'p'->>c.key is null then 'unjudged'
                when (st->'p'->>c.key)::real >= (st->'settings'->>'gate')::real then 'accepted' else 'rejected' end,
           case when st->'p'->>c.key is null then 'unjudged'
                when (st->'travelled') ? c.key then 'travelled'
                when (st->'p'->>c.key)::real < (st->'settings'->>'gate')::real then 'rejected'
                when exists (select 1 from jsonb_array_elements_text(c.value->'targets') t
                              where not (st->'reached') ? t) then 'open'
                else 'spent' end,
           (st->'travelled'->>c.key)::int,
           st->'serves'->>c.key
      from st, jsonb_each(st->'clues') c
     order by 3, 1
$$;

create or replace function aiq.walk_clues(p_run uuid)
returns table (key text, kind text, wave int, source text, targets text[], p real, decision text, state text,
               travelled_wave int, serves text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from aiq.walk_state_clues(aiq.walk_state(p_run))
$$;

-- The text the decider reads for one clue a run raised, under the run's own description or the one named, built by
-- the same aiq.walk_describe_clue the walk uses (REM-1240): a re-judge asks in the walk's own words, with no second
-- copy of them. A clue the run never raised is an error, not null.
create or replace function aiq.walk_clue_text(p_run uuid, p_key text, p_describe text default null)
returns text
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    st  jsonb := aiq.walk_state(p_run);
    inp jsonb := (select input from aiq.walk_run(p_run));
    c   jsonb := coalesce(st->'clues'->p_key, st->'next'->p_key);
begin
    if c is null then
        raise no_data_found using message = format('run %s raised no clue %s', p_run, p_key);
    end if;
    return aiq.walk_describe_clue(inp, aiq.walk_run_graph(p_run), coalesce(p_describe, st->'settings'->>'describe'),
                                  p_key, c->>'kind', c->>'x', c->>'source', c->'targets',
                                  aiq.walk_texts(inp, array[c->>'source'])->>(c->>'source'));
end;
$$;

drop function if exists aiq.walk_waves(uuid);
create or replace function aiq.walk_state_waves(p_state jsonb)
returns table (wave int, reads int, expanded int, judged int, accepted int, fresh real, open_leads int,
               total_reads int)
language sql immutable security invoker set search_path = pg_catalog, public as $$
    with c as materialized (select * from aiq.walk_state_clues(p_state)),
    r as materialized (select * from aiq.walk_state_reads(p_state)),
    -- reached by a wave's end: read, or landed by a travel and queued to read
    reached as materialized (
        select wave, doc from r
        union
        select (w->>'wave')::int, l #>> '{}'
          from jsonb_array_elements(p_state->'waves') w,
               jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)) t,
               jsonb_array_elements(t->'land') l),
    w as (select distinct wave from r)
    select w.wave,
           (select count(*) from r where r.wave = w.wave)::int,
           (select count(*) from r where r.wave = w.wave - 1 and r.expanded)::int,
           (select count(*) from c where c.wave = w.wave and c.p is not null)::int,
           (select count(*) from c where c.wave = w.wave and c.decision = 'accepted')::int,
           (select case when count(*) = 0 then null
                        else (count(*) filter (where exists (
                                 select 1 from c where c.wave = w.wave and c.decision = 'accepted'
                                                   and c.source = r.doc)))::real / count(*) end
              from r where r.wave = w.wave - 1 and r.expanded),
           -- open: accepted, not travelled by the wave's end, and still leading somewhere not yet reached, so
           -- the last wave's count is walk_clues' state 'open'
           (select count(*) from c where c.decision = 'accepted' and c.wave <= w.wave
                                     and (c.travelled_wave is null or c.travelled_wave > w.wave)
                                     and exists (select 1 from unnest(c.targets) t
                                                  where not exists (select 1 from reached x where x.doc = t
                                                                                             and x.wave <= w.wave)))::int,
           (select count(*) from r where r.wave <= w.wave)::int
      from w where w.wave > 0
     order by 1
$$;

create or replace function aiq.walk_waves(p_run uuid)
returns table (wave int, reads int, expanded int, judged int, accepted int, fresh real, open_leads int,
               total_reads int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from aiq.walk_state_waves(aiq.walk_state(p_run))
$$;

create or replace function aiq.walk_summary(p_run uuid)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'question', st->'question', 'settings', st->'settings',
        'scope', (select input - 'question' - 'settings' - 'search' - 'replay' - 'control_of' - 'offline' from aiq.walk_run(p_run)),
        'reads', (select count(*) from aiq.walk_state_reads(st)),
        -- a read step that did not stop the walk records "stop": null, which is JSON, not SQL NULL
        -- the stop a finished run records, or the budget when a finished run recorded none; a run still going has no
        -- stop, and a failed one says it failed (Sirsh's Walks test: a walk not yet started showed 'stopped at wave -1')
        'stop', case when jsonb_typeof(st->'stop') = 'object' then st->'stop'
                     when (select status from aiq.walk_run(p_run)) = 'failed' then
                          jsonb_build_object('reason', 'failed', 'error',
                              (select t.error->>'error' from aiq.walk_tasks(p_run) t where t.status = 'failed'
                                order by t.updated_at limit 1))
                     when (select status from aiq.walk_run(p_run)) in ('completed', 'succeeded') then
                          jsonb_build_object('reason', 'waves', 'wave', jsonb_array_length(st->'waves') - 1)
                end,
        'pending', st->'pending',
        'decider', jsonb_build_object('mode', case when (st->>'offline')::boolean then 'offline'
                                                   when jsonb_typeof(st->'replay') = 'string' then 'replay, then jev'
                                                   else 'jev' end,
                                      'replay', st->'replay', 'verdicts_held', st->'pmap_size'))
      from (select aiq.walk_state(p_run) as st offset 0) x
$$;

-- A finished run's verdicts, as a replay document a later run reads.
create or replace function aiq.walk_verdicts(p_run uuid)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object('model', (select model from claims.deciders where name = 'jev'),
                              'task', aiq.walk_task(st->'settings'->>'describe'),
                              -- a stack walk's verdicts are every judgement it asked for (leads per question,
                              -- assessments, parts, closes), so a replay replays its board too
                              'verdicts', case when st ? 'answers' then st->'answers'
                                               else (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
                                                       from jsonb_each(st->'p') where (st->'clues') ? key) end)
      from (select aiq.walk_state(p_run) as st offset 0) x
$$;

-- The verdicts earlier runs kept for a question under one wording (the source description's unless named), each
-- answered before p_before. The question is its node: a kept document names the node it was asked about, not a
-- string the benchmark gave it (REM-1232).
drop function if exists aiq.walk_kept(text, timestamptz);
drop function if exists aiq.walk_kept(text, timestamptz, text);
drop function if exists aiq.walk_kept(uuid, timestamptz);
create or replace function aiq.walk_kept(p_question uuid, p_before timestamptz default null, p_task text default null)
returns table (key text, p real, at timestamptz, model text, run uuid)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select v.key, (v.value->>'p')::real, (v.value->>'at')::timestamptz, v.value->>'model', (res.metadata->>'run')::uuid
      from content.resources res, jsonb_each(res.metadata->'verdicts') v
     where res.metadata->>'question' = p_question::text
       and res.metadata->>'task' = coalesce(p_task, aiq.walk_task())
       and (p_before is null or (v.value->>'at')::timestamptz < p_before)
$$;

-- Keep a run's verdicts: one document a run, written once and never changed, each verdict with its P, when it was
-- answered and the model. The log is append-only because a run is: a later run keeps its own document beside this
-- one. The verdicts are the document's metadata and its one chunk is '-', so search never finds them. The document
-- names the question's node and the run, so aiq.walk_kept finds it by the node. A run that asked nobody keeps
-- nothing, and neither does one whose question has no node: there is nothing a later run could find it by.
create or replace function aiq.walk_keep(p_run uuid, p_channel text default 'walk-replays')
returns jsonb
language plpgsql volatile security invoker set search_path = pg_catalog, public as $$
declare
    q   jsonb := (select input->'question' from aiq.walk_run(p_run));
    tk  text := aiq.walk_task(aiq.walk_settings((select input from aiq.walk_run(p_run)))->>'describe');
    v   jsonb;
    uri text := 'verdicts:' || p_run;
begin
    if not q ? 'node_id' then
        -- the board needs no question node: its root is a walk_question of its own
        return jsonb_build_object('kept', 0, 'why', 'the question has no node', 'stack', aiq.walk_keep_stack(p_run));
    end if;
    select jsonb_object_agg(a.key, jsonb_build_object('p', a.p, 'at', a.at, 'model', a.model)) into v
      from aiq.walk_answers(p_run) a;
    if v is null then
        return jsonb_build_object('kept', 0, 'stack', aiq.walk_keep_stack(p_run));
    end if;
    perform content.register_text(p_channel, uri, '[{"content": "-"}]'::jsonb,
                format('verdicts of run %s', p_run), uri, null,
                jsonb_build_object('question', q->>'node_id', 'run', p_run, 'task', tk, 'verdicts', v));
    -- the board too, under walk.stack: walk_question nodes and their edges (walk-stack.sql, REM-1245)
    return jsonb_build_object('kept', (select count(*) from jsonb_object_keys(v)), 'uri', uri,
                              'stack', aiq.walk_keep_stack(p_run));
end;
$$;

-- How walks relate, read from what each run was started with, by id (REM-1232): the question's node it asks, the
-- verdict document it replays and the run it is a control of. A query finds "the walks of this question" or "the
-- controls of that run" here, never by matching a benchmark's id or a uri pattern in a run's input.
create or replace view aiq.walk_runs with (security_invoker = true) as
select r.id as run,
       (r.input->'question'->>'node_id')::uuid as question,
       r.input->'question'->>'text' as question_text,
       (r.input->>'replay')::uuid as replays,
       (r.input->>'control_of')::uuid as control_of,
       r.status,
       r.created_at
  from aiq.walk_runs_visible() r;
comment on view aiq.walk_runs is
    'Each walk with what it asks and what it is to other runs: its question''s node, the verdict document it replays and the run it is a control of.';
grant select on aiq.walk_runs to authenticated;

-- ---------------------------------------------------------------- the workflow
drop function if exists aiq.install_walk_workflow(text, text, int);
-- p_model embeds the question for a channel walk: the deployment's default
-- model when it has a provider. With none (a database whose vectors are
-- written directly, as dev/init's demo space is), the workflow has no embed
-- step, and walks a graph or a channel given its order.
create or replace function aiq.install_walk_workflow(p_name text default 'walk', p_decider text default 'jev',
                                                     p_waves int default 10, p_model text default null)
returns text
language plpgsql set search_path = pg_catalog, public as $$
declare
    d       claims.deciders;
    v_model text := coalesce(p_model, (select name from aiq.embedding_models
                                        where is_default and provider is not null limit 1));
    v_q     text := '';
    v_vec   text := 'null';
begin
    if v_model is not null then
        v_q := format($q$
  - id: q
    when: "aiq.walk_needs_vector({{run.$id}}::uuid)"
    embed:
      text: '{{run.question.text}}'
      model: %s
$q$, v_model);
        v_vec := '{{steps.q.result}}';
    end if;
    select * into d from claims.deciders where name = p_decider;
    if not found then
        raise no_data_found using message = format('no decider named %s is configured', p_decider),
            hint = 'insert a row into claims.deciders: its endpoint, model and the worker credential it calls with';
    end if;
    if p_waves not between 1 and 20 then
        raise invalid_parameter_value using message = 'a walk has 1 to 20 waves (repeat''s bound)';
    end if;
    perform workflow.define_yaml(format($y$
name: %1$s
steps:%6$s
  - id: start
    %7$s
    sql: "select aiq.walk_start({{run.$id}}::uuid, %8$s::vector) as state"
  - id: wave
    needs: [start]
    repeat:
      max: %4$s
      until: "({{steps.read.result.0.state.dry}})::boolean"
      steps:
        - id: assess
          matrix:
            rows: "select chunk, keys, body from aiq.walk_stack_requests({{run.$id}}::uuid, 'assess', '%5$s')"
            max_fanout: 200
            continue_on: failed
            template:
              rest:
                url: %2$s
                method: POST
                credential_ref: %3$s
                body: '{{item.body}}'
        - id: shape
          needs: [assess]
          matrix:
            rows: "select chunk, keys, body from aiq.walk_stack_requests({{run.$id}}::uuid, 'shape', '%5$s')"
            max_fanout: 200
            continue_on: failed
            template:
              rest:
                url: %2$s
                method: POST
                credential_ref: %3$s
                body: '{{item.body}}'
        - id: stack
          needs: [shape]
          sql: "select aiq.walk_stack_move({{run.$id}}::uuid) as state"
        - id: judge
          needs: [stack]
          matrix:
            rows: "select chunk, keys, body from aiq.walk_requests({{run.$id}}::uuid, '%5$s')"
            max_fanout: 200
            continue_on: failed
            template:
              rest:
                url: %2$s
                method: POST
                credential_ref: %3$s
                body: '{{item.body}}'
        - id: read
          needs: [judge]
          sql: "select aiq.walk_read({{run.$id}}::uuid) as state"
  - id: keep
    needs: [wave]
    sql: {statement: "select aiq.walk_keep({{run.$id}}::uuid) as kept", write: true}
$y$, p_name, d.endpoint, d.credential_ref, p_waves, p_decider, v_q,
      case when v_model is not null then 'needs: [q]' else '' end, v_vec));
    return format('%s: a clue walk of up to %s waves, judged by %s, %s', p_name, p_waves, p_decider,
                  coalesce('questions embedded by ' || v_model, 'with no embed step (graph walks, or a given order)'));
end;
$$;

grant execute on function aiq.walk_task(text), aiq.walk_settings(jsonb), aiq.walk_needs_vector(uuid), aiq.walk_graph(jsonb, timestamptz),
                          aiq.walk_keys(jsonb), aiq.walk_texts(jsonb, text[]), aiq.walk_graph_version(jsonb),
                          aiq.walk_graph_uri(jsonb, jsonb), aiq.walk_graph_build(jsonb, timestamptz), aiq.walk_index(jsonb, text),
                          aiq.walk_answers(uuid), aiq.walk_kept(uuid, timestamptz, text), aiq.walk_keep(uuid, text),
                          aiq.walk_signs(jsonb, text, jsonb),
                          aiq.walk_snippet(text, text), aiq.walk_state(uuid), aiq.walk_start(uuid, vector),
                          aiq.walk_run_graph(uuid),
                          aiq.walk_requests(uuid, text), aiq.walk_read(uuid), aiq.walk_reads(uuid), aiq.walk_search_order(uuid),
                          aiq.walk_clues(uuid), aiq.walk_waves(uuid), aiq.walk_summary(uuid), aiq.walk_verdicts(uuid)
    to authenticated;
revoke all on function aiq.install_walk_workflow(text, text, int, text) from public;
