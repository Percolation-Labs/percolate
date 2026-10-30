# Muddling Through: run the example

A walk reads search results, follows leads, and records its decisions in Postgres. This example compares that walk with search, explains what it missed, and queries a changing fact on both of its clocks.

This guide accompanies [Muddling Through, as a Query](https://medium.com/@mrsirsh/muddling-through-as-a-query-cefa0edd6681). The [full research paper](https://www.percolationlabs.ai/research/durable-iterative-bitemporal-queries) gives the measurements and their limits; [Kappa](https://www.percolationlabs.ai/research/kappa-memory-for-a-local-decider) develops the memory problem behind choosing the next read.

## Before you start

You need Git, Bash, curl, Docker with Compose, Python 3.11 or later with `venv`, and the PostgreSQL `psql` client. Docker must be running. The initial run downloads images, Python packages and the public BEAM dataset. Its database uses port **5801**, with the other services on **5802–5807**.

New to Percolate? The [installation guide](https://percolation-labs.github.io/get-percolate/install.html) and [Your first memory](https://percolation-labs.github.io/get-percolate/quickstart.html) introduce the stack and a simple semantic lookup. The runner below starts its own stack, so a separate installation is not required for this example.

**The runner recreates its Docker project, including its database volumes, on every run.** Keep your own data in a different project. The default project is `muddling-through`; `PROJECT` and `PG_PORT` can select another project and a free block of seven ports.

## Run the published example

Use the release tag for the scripts and the explicit image and Python package versions below:

```bash
git clone --depth 1 --branch v0.2.35 \
  https://github.com/Percolation-Labs/percolate.git
cd percolate/dev/examples/muddling-through

IMG=percolationlabs/percolate-postgres:19-0.2.35 \
CORE='percolate-core[sample]==0.2.16' \
  ./run.sh "$PWD/run"
```

The runner downloads two BEAM conversations, checks the download, loads their prepared vectors and recorded Jev verdicts, indexes the links, and runs the numbered blocks. It also loads a small synthetic graph used by the certificate and exploration examples. **No model API key or paid model call is needed for these replays.**

The setup includes these commands; you do not need to run them a second time:

```bash
percolate sample load samples/beam
percolate sample load samples/walk-0
percolate walk index --source beam-1m22
percolate walk index --source beam-1m35
```

Successful completion prints `all blocks ok:` followed by the run directory. Full output is in `run/captures/`. The runner checks the headline counts and compares the blocks that have checked-in expectations with `expected/*.txt`.

## Read one walk

After the runner finishes, connect to its database:

```bash
psql postgres://p8:p8@localhost:5801/percolate
```

List the walks, copy a run ID, and inspect its waves:

```sql
select run, question_text, status
from aiq.walk_runs
order by created_at;

\prompt 'Run ID: ' run
select wave, reads, open_leads
from aiq.walk_waves(:'run');
```

A wave shows how much the walk has read and how many leads remain. The following files contain the complete experiments, including their SQL and the setup each needs:

| File in `blocks/` | What to inspect |
| --- | --- |
| `10-walk-vs-search.sh` | The holiday question: evidence found at equal read budgets. |
| `20-certificate.sh` | A synthetic graph whose open leads count down to zero. |
| `30-a-miss-explained.sh` | A missed answer, with the lead's recorded fate. |
| `40-near-misses.sh` | Exploration of leads just below the acceptance threshold. |
| `45-audit.sh` | The audit and missing-evidence explanations. |
| `60-time.sh` | When a budget held and when the agent recorded its change. |
| `70-wave-by-wave.sh`, `71-blind.sh` | The successive reads and a control using random choices. |

The answer key stays outside the walk. Evaluation code in `harness/` uses it to measure evidence coverage; coverage does not establish the quality of a model's final answer. The dataset and its licence are described in [samples/beam/README.md](samples/beam/README.md), with credit to [BEAM](https://huggingface.co/datasets/Mohammadta/BEAM).

## Stop and resume the stack

To stop the services while keeping the data:

```bash
cd run
docker compose stop
```

From that same directory, `docker compose start` brings them back. Running `run.sh` again starts the example afresh and removes the previous project's volumes.

## Release notes and troubleshooting

- **The commands above deliberately use v0.2.35.** Its runner defaults to older packages unless `IMG` and `CORE` are supplied. It also downloads Compose from `get-percolate/main`, so that dependency is not frozen by the two pins. Later source versions resolve Compose and package versions together; do not mix unreleased blocks with an older image.
- If the stack cannot start, read `run/captures/00-stack.txt` and check Docker and the seven ports. To choose another range, add `PROJECT=muddling-through-demo PG_PORT=6801` before the runner command; connect to that port afterward.
- If a block fails, its capture identifies the first failed step. Keep that output before rerunning, since the runner resets the project. A database connection lost during a run can indicate Docker has run out of memory.
- [TOUR.md](TOUR.md) records work on a fuller fresh-machine tour, including the UI and MCP. It is a draft with unreleased placeholders; use this README for the released command-line example.

This README's commands and paths were checked against the v0.2.35 source and its published version manifest. Adding the README did not rerun the full Docker walkthrough.
