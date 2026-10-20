# Percolate

An AI workflow engine and agent memory inside Postgres. Agents, workflows, runs, documents and the graph over them
are rows, so the trace of a run is something you query.

This repository holds the source of both halves:

| path | what it is |
|---|---|
| `extension/percolate` | the `percolate` extension: pure SQL, installable by a non-superuser so row-level security is real |
| `extension/percolate_parser` | the `percolate_parser` extension: the compiled parsers, in Rust with [pgrx](https://github.com/pgcentralfoundation/pgrx) |
| `specs/*/*.sql` | the schema the extension is generated from, one directory per subsystem |
| `core/` | a read-only mirror of percolate-core (a private repository), the Python processes in front of the database: worker, Content Server, Agent Runtime. percolate-core releases from its own repository (PyPI's trusted publisher is bound there), and `core/` follows it; change it there, not here, or the next sync overwrites the change |
| `dev/` | the image build, the install CI runs, the tests and the upgrade gates |

To install and run Percolate, use [get-percolate](https://github.com/Percolation-Labs/get-percolate). It has the
compose file, the Helm chart and the docs. The images are `percolationlabs/percolate-postgres` and
`percolationlabs/percolate-core` on Docker Hub, and the Python package is `percolate-core` on PyPI.

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

Some comments and tests here still point at those: a path into the internal repository, or a prose spec that is
not in this tree. They are being replaced with the point itself; `dev/no-private-citations.py --check`, one of the tree gates,
refuses a new one, and `--all` counts what is left.

## The earlier Percolate

The Python project that used this name until October 2026 (`percolate-db` on PyPI) is now
[percolate-experiment](https://github.com/Percolation-Labs/percolate-experiment), with its full history, branches
and tags. Its GitHub releases are still listed here.

## Licence

MIT. See [LICENSE](LICENSE).
