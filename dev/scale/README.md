# Scale harness

Every number in [`specs/workflow-engine/scale.md`](../../specs/workflow-engine/scale.md)
came from here. The point of the directory is that they can be re-run rather
than trusted, and that a regression in the claim path shows up as a number
falling rather than as a support ticket.

```bash
./run.sh                      # the full sweep, ~5 minutes
./run.sh --depth 100000       # a smaller backlog
DSN="postgres://…" ./run.sh   # against something other than the compose stack
```

The defaults, container `p8-dev-db` and database `p8experiment`, are this
repository's dev stack. Against your own, set `CONTAINER` or `DSN`.

## What it measures, and why these three

The three are the engine's hot paths, and they were chosen because each one is
touched on every task rather than once per run.

| Probe | The question | Why it matters |
|---|---|---|
| `claim` | what does `claim_task` cost at depth, with N workers competing? | every worker, every task |
| `depth` | what does `queue_depth()` cost? | KEDA calls it every 30 s per pool |
| `fanin` | what does completing N children that feed one successor cost? | the shape `matrix` produces |

## The thing this harness exists to catch

**A shallow queue hides everything.** Both defects it found are invisible at
fixture scale and appear only when a queue is deep — which is the condition the
engine exists to absorb, and the one no test in this repo had ever created. If
you add a probe here, make it deep by default; a probe that passes on a hundred
rows is a probe that will pass on the day it should have failed.

## Beside it

[`walks.sh`](walks.sh) starts many offline walks over one seeded scope
(`06-walks-seed.sql`: 2,000 items, about 10,000 links, 20,000 other resources)
and samples Postgres's private memory every 2 s; it fails if a walk does not
succeed or a backend is killed (REM-1228). On 30 Oct, 250 walks 16 at a time:
all succeeded in 34 s, no backend killed, 589 MB private in total and 44 MB in
the largest backend; 39 s without `idx_resources_uri`.

[`kind/`](kind/README.md) runs the claim probe on a three-node cluster, and
[`research/`](research/README.md) holds a separate study with its own README.

## Cleaning up

The harness writes into `workflow.tasks` under a `scale_probe` definition and
its own runs. `./run.sh --clean` removes them.
