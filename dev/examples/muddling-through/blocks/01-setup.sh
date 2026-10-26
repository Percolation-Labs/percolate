# Setup: load the two samples, their vectors with them, and index both conversations.
percolate sample load samples/beam
percolate sample load samples/walk-0

# Every piece arrived with its vector, so the links can be built at once.
percolate walk index --source beam-1m22
percolate walk index --source beam-1m35

# The walk itself is a workflow the extension ships: install it once, under the name the steps start.
psql "$P8_DSN" -c "select aiq.install_walk_workflow()"

psql "$P8_DSN" -c "select relation, count(*) from aiq.edges_current where relation like 'walk_%' group by 1 order by 1"
