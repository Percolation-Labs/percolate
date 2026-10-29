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
pip install "percolate-core[sample,ui]==0.2.XX"
```

No key is needed: the embeddings come from bge-small in the stack's own worker, and the walks replay Jev's recorded
verdicts at no cost.

## 2. Sign in (to run)

```bash
export P8_DSN=postgres://p8:p8@localhost:5432/percolate
uid=$(psql "$P8_DSN" -Atc "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')")
# signed inside the stack, which holds the secret it verifies with (get-percolate's quickstart)
export TOKEN=$(docker compose exec -T content percolate auth token --sub "$uid")
```

Open question for the run: which users the Walks screen needs besides the admin (a plain reader, to show what a
viewer sees under row-level security?).

## 3. Fetch the example's data (to run)

The bundle is a release asset of this repository, checked by its sha256 before it is loaded:

```bash
ASSET=<the bundle's name>         # set at the release, with its sha256; the full one is about 158 MB
curl -fsSLO "https://github.com/Percolation-Labs/percolate/releases/download/$TAG/$ASSET"
echo "<sha256>  $ASSET" | sha256sum -c -
tar xzf "$ASSET"
percolate sample load beam-walks
percolate walk index --source beam-1m22
percolate walk index --source beam-1m35
percolate sample load beam-walks/walks
```

The walks load last: their SQL installs the walk workflow, builds each walk's graph for its settings and starts each
walk offline from Jev's recorded verdicts, so the links must be indexed first (`walk index` is the Python indexer,
so it is the reader's step, not the bundle's).

What it holds is cory's `harness/bundle.py` output: the two BEAM conversations with their vectors, each question by
its words only (no answer key in the database), the answer key in `oracle/` for oracle mode, and the walks the
article shows with Jev's verdicts, so they replay offline.

Then two checks a reader's install has to pass before anything else means much (cory, 29 Oct: his bundle test ran
against a CI fixture, so a fresh install is where they are proven):

```sql
-- one default embedding model, and it is the stack's bge-small: the sample's vectors were made with it
select name, dim, provider, is_default from aiq.embedding_models;
-- every walk the bundle started ran to the end: each one's question step embeds through the stack's own service
select status, count(*) from aiq.walk_runs group by 1;
-- every replayed walk is the walk it replays: walk_summary labels a replay that met a lead with no recorded
-- verdict as not faithful, with the count (bill, 29 Oct); every row here must read true
select r.run, aiq.walk_summary(r.run)->'decider'->'faithful' as faithful
  from aiq.walk_runs r where r.replays is not null;
```

## 4. See the walks in the app (to run)

The Walks screen is core's own UI, which the compose stack does not start: the reader starts it.

```bash
pip install "percolate-core[ui]==0.2.XX"
export P8_UI_REST_URL=http://localhost:3000 P8_UI_CORE_URL=http://localhost:8080 P8_UI_CONTENT_URL=http://localhost:8081
percolate ui serve --host 127.0.0.1 --port 8082
```

Open <http://localhost:8082/#/walks> ('Walks' in the sidebar) and sign in with the token from step 2. A walk is
readable by the account that ran it, its org and operators; the bundle's walks are started as the first user, so that
one account sees them. Oracle mode: in a walk, open 'oracle' and choose `beam-walks/oracle/all.json`. To fill in on the
run: one screenshot each of a question, its stack, its graph and a finished walk with oracle mode off and on.

The app's icon: `curl -sI http://localhost:8082/favicon.svg` answers 200 with `image/svg+xml`, and the browser tab
shows it (checked by eye on the Mac leg; the runner checks the page links it and keeps a screenshot of the Walks screen).

## 5. Query it from your own client (to run)

The same rows the screen shows, from psql:

```sql
select run, question_text, status from aiq.walk_runs order by created_at;
select wave, reads, judged, accepted, open_leads from aiq.walk_waves(:'run');
```

and from one graphical client (on the Mac; which one is chosen at the run), connected to the same `P8_DSN`.

## 5b. Ask Claude, over MCP (to run, Mac leg)

Sirsh's addition (29 Oct): connect Claude to Percolate the way a reader would, then use it the way a reader would. The
stack's query MCP server listens on 127.0.0.1 only, and takes the reader's own token:

```bash
claude mcp add --transport http percolate http://localhost:8090 --header "Authorization: Bearer $TOKEN"
```

Then, in Claude: ask what walks there are, open one and ask why it missed a piece of evidence. To fill in on the run:
the questions asked, what Claude called, and whether the answers match the rows psql returns. This needs Claude, so it
runs on the Mac against a stack started the same way, not on the runner.

## 6. Rerun the article's experiments (to run)

Each experiment the article quotes, run as its block prints it. The tour diffs every number a block prints against
the article's own figure for it and fails on a difference beyond the noise the article states (bill, 29 Oct). The
data comes only from the release asset's public URL: the runner checks nothing out and reads no registry cache.
Open question for the run: where a reader gets the blocks without a checkout (the bundle, or the release's source
archive).

## Every surface a reader touches

Each is checked on the run, and a stuck reader at any of them becomes a board card with its owner.

| surface | where | leg |
|---|---|---|
| the release page and its assets | github.com/Percolation-Labs/percolate/releases | runner |
| the install | get-percolate's compose at the tag, pip | runner |
| the docs links the article and the install guide cite | percolation-labs.github.io/get-percolate | runner (every link fetched) |
| sign-in: the first user and a token | `rbac.bootstrap_admin`, `percolate auth token` | runner |
| the CLI | `percolate sample load`, `walk index`, `auth token`, `ui serve` | runner |
| the Walks screen | localhost:8082/#/walks | runner (headless), Mac (by eye) |
| psql | `P8_DSN` | runner |
| a graphical Postgres client | the same `P8_DSN` | Mac |
| Claude over MCP | localhost:8090 with the token | Mac |
| the article's experiment blocks | each block's output against the article | runner |

## Where a reader got stuck

- **Sign-in (smoke, 29 Oct, run 40943231212).** `percolate auth token` from the pip-installed CLI refuses with "no
  signing secret. Pass --secret or set P8_JWT_SECRET", because the secret lives in the stack. The tour now mints the
  token where get-percolate's quickstart does, inside the stack's content container. A reader following the
  quickstart would not hit this; one who reached for the CLI the article installs would.
- **A wrong check of mine (smoke 2, run 40946384658).** The tour counted walk_clues' 'unjudged' leads as the
  replay's test and failed on 2,242 and 20. walk_clues reads only the plain verdict map, and a stack-on walk keeps
  its verdicts per open question, so the count says nothing about whether the replay held a verdict. The test is
  walk_summary's decider.faithful (#326), which reads both.
