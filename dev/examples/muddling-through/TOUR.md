# The fresh-machine tour (draft)

The article's walkthrough, as a reader with nothing installed runs it: install the latest Percolate release, fetch the
example's data from where it is published, see the walks in the app, query them from a Postgres client of your own,
and rerun every experiment the article quotes.

DRAFT, 29 Oct (timmy). Written before the release it tours exists: every step below is marked **run** (done on a clean
machine, with its output) or **to run**. The run happens when the release is out; this file is rewritten as it goes,
and every place a reader got stuck is listed at the end with what fixed it.

## The clean machine

A GitHub-hosted `ubuntu-latest` runner, started fresh for each run by `.github/workflows/fresh-machine-tour.yml`:
no Docker images, no pip cache, no Percolate checkout. The workflow runs the same commands this file shows, in the
same order, and keeps every step's output and the app's screenshots as artifacts.

One step cannot run there: a graphical Postgres client. It runs on a Mac against a stack started the same way, and is
marked as such.

## 1. Install the release (to run)

Docker and Python 3.11 or later are all a reader needs. The stack is get-percolate's compose file at the release's tag:

```bash
mkdir muddling-through && cd muddling-through
TAG=v0.2.XX                       # the release this tour proves; filled in when it is out
curl -fsSL "https://raw.githubusercontent.com/Percolation-Labs/get-percolate/$TAG/compose/docker-compose.yml" -o docker-compose.yml
docker compose up -d --wait
python3 -m venv .venv && . .venv/bin/activate
pip install "percolate-core[sample]==0.2.XX"
```

No key is needed: the embeddings come from bge-small in the stack's own worker, and the walks replay Jev's recorded
verdicts at no cost.

## 2. Sign in (to run)

```bash
export P8_DSN=postgres://p8:p8@localhost:5432/percolate
psql "$P8_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')"
export TOKEN=$(percolate auth token --email me@example.com)
```

Open question for the run: which users the Walks screen needs besides the admin (a plain reader, to show what a
viewer sees under row-level security?).

## 3. Fetch the example's data (to run)

The bundle is a release asset of this repository, checked by its sha256 before it is loaded:

```bash
curl -fsSLO "https://github.com/Percolation-Labs/percolate/releases/download/$TAG/beam-walks.tar.gz"
echo "<sha256>  beam-walks.tar.gz" | sha256sum -c -
tar xzf beam-walks.tar.gz
percolate sample load beam-walks
percolate sample load beam-walks/walks
percolate walk index --source beam-1m22
percolate walk index --source beam-1m35
```

What it holds is cory's `harness/bundle.py` output: the two BEAM conversations with their vectors, each question by
its words only (no answer key in the database), the answer key in `oracle/` for oracle mode, and the walks the
article shows with Jev's verdicts, so they replay offline.

## 4. See the walks in the app (to run)

The Walks screen is part of core's UI. To fill in on the run: the address it is served on, how a reader opens it, and
one screenshot each of a question, its stack, its graph and a finished walk with oracle mode on and off.

## 5. Query it from your own client (to run)

The same rows the screen shows, from psql:

```sql
select run, question_text, status from aiq.walk_runs order by created_at;
select wave, reads, judged, accepted, open_leads from aiq.walk_waves(:'run');
```

and from one graphical client (on the Mac; which one is chosen at the run), connected to the same `P8_DSN`.

## 6. Rerun the article's experiments (to run)

Each experiment the article quotes, run as its block prints it, and its output compared with what the article says.
Open question for the run: where a reader gets the blocks without a checkout (the bundle, or the release's source
archive).

## Where a reader got stuck

Filled in from the run.
