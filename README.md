# Percolate

An AI workflow engine and agent memory inside Postgres. Agents, workflows, runs, documents and the graph over them
are rows, so the trace of a run is something you query.

**Docs: <https://percolation-labs.github.io/get-percolate>**: [install](https://percolation-labs.github.io/get-percolate/install.html),
[your first memory](https://percolation-labs.github.io/get-percolate/quickstart.html) and everything after them.

## Run it

Three ways in, and all three install the same release. The compose file, the Helm chart and the installer are
published from [get-percolate](https://github.com/Percolation-Labs/get-percolate), which pins each release's
images.

### Docker Compose

```bash
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml -o docker-compose.yml
docker compose up -d --wait
```

This brings up Postgres 19 with both extensions, PostgREST, the outbound and ingestion workers, the Content Server,
the Agent Runtime, the query MCP server and an S3 store. No model key is needed: the workers carry a CPU embedding
model. For agent turns, put `OPENAI_API_KEY=sk-...` in a `.env` beside the file before `up`. If port 5432 is taken,
add `P8_PG_PORT=5433` there too. [Your first memory](https://percolation-labs.github.io/get-percolate/quickstart.html)
then takes you to a first query in about four minutes: sign in, write a note, and find it again by meaning.

### Helm

The chart is `oci://ghcr.io/percolation-labs/charts/percolate`. It is also indexed at
`https://percolation-labs.github.io/get-percolate/charts`. It is a plain chart with no CRDs, so Flux and Argo CD take
it as it is.

```bash
cat > percolate-values.yaml <<EOF
secrets:
  postgresPassword: $(openssl rand -hex 24)
  authenticatorPassword: $(openssl rand -hex 24)
  workerPassword: $(openssl rand -hex 24)
  jwtSecret: $(openssl rand -hex 32)
  s3Key: $(openssl rand -hex 16)
  s3Secret: $(openssl rand -hex 24)
  openaiApiKey: "${OPENAI_API_KEY:-}"
  llmApiKey: "${OPENAI_API_KEY:-}"
EOF
helm install percolate oci://ghcr.io/percolation-labs/charts/percolate \
  --namespace percolate --create-namespace -f percolate-values.yaml
```

Its values are documented in
[`charts/percolate/README.md`](https://github.com/Percolation-Labs/get-percolate/blob/main/charts/percolate/README.md).

### Your own Postgres 19

```bash
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/install.sh | sh
```

This installs `percolate` (pure SQL) and `percolate_parser` (prebuilt for linux/amd64, linux/arm64 and macos/arm64)
into a database you already run. The [install page](https://percolation-labs.github.io/get-percolate/install.html)
covers the roles and `bootstrap.sql`.

### What is published

| what | where |
|---|---|
| the database, with both extensions | `percolationlabs/percolate-postgres:19-<version>` on Docker Hub |
| the worker, Content Server and Agent Runtime | `percolationlabs/percolate-core` on Docker Hub, and `percolate-core` on PyPI |
| the extensions on their own | each `v<version>` release of [get-percolate](https://github.com/Percolation-Labs/get-percolate/releases) |
| the Helm chart | `oci://ghcr.io/percolation-labs/charts/percolate` |

## The source

This repository holds the source of both halves:

| path | what it is |
|---|---|
| `extension/percolate` | the `percolate` extension: pure SQL, installable by a non-superuser so row-level security is real |
| `extension/percolate_parser` | the `percolate_parser` extension: the compiled parsers, in Rust with [pgrx](https://github.com/pgcentralfoundation/pgrx) |
| `specs/*/*.sql` | the schema the extension is generated from, one directory per subsystem |
| `core/` | a read-only mirror of percolate-core (a private repository), the Python processes in front of the database: worker, Content Server, Agent Runtime. percolate-core releases from its own repository (PyPI's trusted publisher is bound there), and `core/` follows it; change it there, not here, or the next sync overwrites the change |
| `dev/` | the image build, the install CI runs, the tests and the upgrade gates |

## Building and testing

The Postgres image, with the parser compiled from this tree (Docker with at least 6 GB of memory):

```bash
pip install pyyaml
REBUILD_PARSER=1 TAG=percolate-postgres:mine dev/build-image.sh
```

The extension installed as CI installs it, in a container of its own, then every gate CI runs, including the
tests, the upgrade checks and the docs' worked examples:

```bash
IMAGE=percolate-postgres:mine CONTAINER=p8-mine DB=p8mine dev/ci-database.sh
CONTAINER=p8-mine DB=p8mine dev/check.sh
```

[CONTRIBUTING.md](CONTRIBUTING.md) lists what you need and how long each step takes.

`extension/percolate/sql/percolate--<version>.sql` is generated. Edit `specs/`, then run
`python3 extension/percolate/build-sql.py`. Its upgrade scripts are written for every released version, read from
the `v*` tags.

## What is not in this repository

Percolate was cut out of Percolation Labs' internal repository, and these stayed there on purpose:

- the work board, the decision records, postmortems and the team's working notes;
- research notes, experiments and the evaluation fixtures built from private data;
- the hosted application at percolationlabs.ai, its deployment and production configuration;
- the source of percolate-core, which `core/` mirrors read-only (see the table above);
- for now, the prose design documents behind `specs/`: only their SQL moved at the cut, and whether the prose is
  published is being decided.

Nothing here points at those: no path into the internal repository, and no prose spec that is not in this tree.
Each was published beside its schema or replaced with the point itself, and `dev/no-private-citations.py --check`,
one of the tree gates, refuses any that returns.

## The earlier Percolate

The Python project that used this name until October 2026 (`percolate-db` on PyPI) is now
[percolate-experiment](https://github.com/Percolation-Labs/percolate-experiment), with its full history, branches
and tags. Its GitHub releases are still listed here.

## Licence

MIT. See [LICENSE](LICENSE).
