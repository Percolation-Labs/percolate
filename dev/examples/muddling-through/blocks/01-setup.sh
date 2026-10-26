# Setup: load the two samples, wait for the worker to embed BEAM, and index both conversations.
percolate sample load samples/beam
percolate sample load samples/walk-0

# The worker embeds 2,159 exchanges in the background (bge-small, in the stack); index once it has.
until [ "$(psql "$P8_DSN" -Atc "select count(*) from workflow.runs r join workflow.definitions d
                                 on d.id = r.workflow_def_id
                                where d.name = 'embed_text' and r.status = 'running'")" = 0 ]; do sleep 10; done

percolate walk index --source beam-1m22
percolate walk index --source beam-1m35

psql "$P8_DSN" -c "select relation, count(*) from aiq.edges_current where relation like 'walk_%' group by 1 order by 1"
