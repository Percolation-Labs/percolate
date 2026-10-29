# Setup: download BEAM from its public release, cut the two conversations from it, load both samples, and index them.
# The sample ships only the vectors the stack's own bge-small gave each piece, matched to the downloaded text by sha256.
pip install -q --disable-pip-version-check pyarrow
python3 harness/beam_fetch.py samples/beam
percolate sample load samples/beam
percolate sample load samples/walk-0

# Keyless (walk.md §5): a question enters the database by its words alone. A loader that copied BEAM's answer and
# rubric into question metadata did so unseen for a run (cory, REM-1245), so the run stops here if any is stored.
KEYED=$(psql "$P8_DSN" -Atc "select count(*) from content.resources where uri like 'question:%'
                               and (metadata ? 'answer' or metadata ? 'rubric' or metadata ? 'gold')")
if [ "$KEYED" != 0 ]; then
  echo "the answer key is in the database: $KEYED question resources carry answer, rubric or gold"; exit 1
fi

# Every piece arrived with its vector, so the links can be built at once.
percolate walk index --source beam-1m22
percolate walk index --source beam-1m35
# The replayed walks run at span 2 and cap 10, the settings their verdicts were recorded under, and a graph is kept per
# settings: build that one now too, or the first such walk builds it inside its own step and can hit the statement timeout.
psql "$P8_DSN" -Atc "select aiq.walk_index(jsonb_build_object('channel', c, 'settings', jsonb_build_object('span', 2, 'cap', 10)))->>'uri'
                       from unnest(array['beam-1m22', 'beam-1m35']) c" > /dev/null

# The walk itself is a workflow the extension ships: install it once, under the name the steps start.
psql "$P8_DSN" -c "select aiq.install_walk_workflow()"

psql "$P8_DSN" -c "select relation, count(*) from aiq.edges_current where relation like 'walk_%' group by 1 order by 1"
