# Releases

What was published, and which commit each published version was cut from.

This file exists because a tag is not self-describing once one of them is
wrong, and because the packaging decision record made the core pin bump
conditional on "the `percolate-core` release notes" — a precondition that had
never existed. The generated GitHub Release bodies are bare compare links;
this is the account that is written on purpose.

`.github/workflows/release.yml` is the mechanism. It publishes to PyPI and
Docker Hub first and tags last, so a failed run leaves a bumped, untagged tree
that the next run finishes. The tag is the commit point.

It also writes the tail, which through 0.1.11 was done by hand and left every
PR red until somebody did (REM-150). After the tag, `after_release.py` moves
the README's image pins, drops the changelog's "(unreleased)", adds this file's
row and opens the next patch. Then it runs `dev/check-version.sh` and
`dev/check-releases.sh` before pushing. **The paragraph saying why a version
exists is still written by a person**; the run summary says when it is owed.
Because main now sits one patch past the latest tag, the number a release
publishes counts from that tag (`bump_version.py release`). To retry a release
that did not finish, dispatch the same bump again.

## The invariant

**`v<x>` names the commit whose `pyproject.toml` says `<x>`.** The `publish` job's tag step
checks out `needs.version.outputs.sha` — the commit `build` and `image` used —
and then refuses to tag at all if the tree it landed on disagrees with the
version it is about to tag. Both halves are needed: the `ref:` is a value
handed between jobs, and before the assertion existed a wrong one tagged
silently.

## Published versions

| Version | Tag | Commit | GitHub Release |
| -- | -- | -- | -- |
| 0.1.0 – 0.1.3 | none | — | none |
| 0.1.4 | `v0.1.4` | `db0a944` | yes (backfilled) |
| 0.1.5 | `v0.1.5` | `6669bc4` | yes (backfilled) |
| 0.1.6 | `v0.1.6` | `d8ae150` | yes |
| 0.1.7 | `v0.1.7` | `939a5be` | yes |
| 0.1.8 | `v0.1.8` → `8c03d2a` | **`91ef61b`** | yes |
| 0.1.9 | `v0.1.9` | `014b75e` | yes |
| 0.1.10 | `v0.1.10` | `3612268` | yes |
| 0.1.11 | `v0.1.11` | `4d583e8` | yes |
| 0.1.12 | `v0.1.12` | `c8e6878` | yes |
| 0.1.13 | `v0.1.13` | `5e34fdb` | yes |
| 0.2.0 | `v0.2.0` | `1f16cc8` | yes |
| 0.2.1 | `v0.2.1` | `0779633` | yes |
| 0.2.2 | `v0.2.2` | `7bd5076` | yes |
| 0.2.3 | `v0.2.3` | `6be6494` | yes |
| 0.2.4 | `v0.2.4` | `959af85` | yes |
| 0.2.5 | `v0.2.5` | `346dcaf` | yes |
| 0.2.6 | `v0.2.6` | `23c813b` | yes |
| 0.2.7 | `v0.2.7` | `428d597` | yes |
| 0.2.8 | `v0.2.8` | `9e5b791` | yes |
| 0.2.9 | `v0.2.9` | `f823c4f` | yes |
| 0.2.10 | `v0.2.10` | `437fd21` | yes |
| 0.2.11 | `v0.2.11` | `d13796c` | yes |
| 0.2.12 | `v0.2.12` | `6673c6a` | yes |

0.1.0–0.1.3 went to PyPI before releasing was a workflow. There is nothing to
recover: the wheels are on PyPI and no tag was ever pushed, and no Release page
can be created for a tag that does not exist.

0.1.9 is the first release where the invariant above was checked rather than
trusted: `v0.1.9` names `014b75e`, whose `pyproject.toml` says `0.1.9`. It also
published as a **retry** — the tree carried `0.1.9` with no tag, which
`release.yml` reads as a release that did not finish, so it published that
rather than bumping past it. The run said so itself: *"0.1.9 is in the tree and
untagged -- publishing THAT rather than bumping."*

0.1.10 carries three defects that were in 0.1.9 and reachable by a reader, which
is why it was cut the same evening rather than waiting:

* **A NUL byte anywhere in a turn's rows or a document's chunks aborted the
  write.** Postgres `text` cannot hold U+0000 and both writes hand Postgres a
  jsonb argument the SQL side reads back with `->>`. A live third-party tool
  result took a turn to `failed` after the model and the tools had already run;
  one NUL in a 777-byte upload took the ingest task terminal, cancelled the three
  tasks after it and wrote zero chunks. `core.text.without_nul` (REM-146).
* **The caller's ambient context went to every tool destination.** A registered
  third party echoed back a live `X-P8-User-Id` and `X-P8-Session-Id` while the
  same request was correctly being refused the caller's token. `X-P8-*` now
  crosses only to an origin in `P8_TOOL_AUTH_ORIGINS` (REM-148).
* **`percolate sample load` wrote a channel nobody could read.** Owner and
  visibility were left to the column defaults -- null and `private` -- and
  extension 0.2.0, published two hours earlier, is the version that added
  `channels_readable_by_somebody` to refuse that row. So step three of
  `install.md` died on a check constraint (REM-147).

It published as a **retry**, like 0.1.9: the tree carried 0.1.10 with no tag
from `795459a`'s *"0.1.10 opens, because 0.1.9 is spent"*, and `release.yml`
reads that as a release that did not finish. The run said so itself -- *"0.1.10
is in the tree and untagged -- publishing THAT rather than bumping"* -- which is
what a `bump: patch` dispatch was relying on and was confirmed by a
`publish: false` run first rather than assumed.

`v0.1.10` names `3612268`, whose `pyproject.toml` says `0.1.10`.

0.1.11 exists because 0.1.10 did not fix what it was cut for. `percolate sample
load` has TWO explicit-value defects against 0.2.0's tightened columns -- the
channel insert and the edge insert -- and 0.1.10 carried only the first, because
it was verified by probing the constraint with two SQL statements rather than by
running the command. Nothing about a channel names an edge. Running
`percolate sample load --as-email … --skip-documents`, which is `ci/coldstart.sh`'s
own invocation, against the published `percolate-postgres:19-0.2.0` found the
second in one pass and established there was no third; `cold-start` is green on
get-percolate's `main` from 0.1.11. The class has a name: a fix proved by a
probe, and a release cut on it, before the command it was for had been run.

`v0.1.11` names `4d583e8`, whose `pyproject.toml` says `0.1.11`. Both releases were
dispatched `publish: false` first, so the retry-vs-bump decision was read off the
run's own annotation before anything was published rather than assumed.

0.1.12 is what a stock install needed to run a scheduled agent at all. No
shipped deployment served `/internal/run`, the runtime's login could not become
`worker` to complete a task, `agent serve` never mounted the delegation gateway,
and the sample's own agent had no query tool server to read the sample with.
Behind those came the refusals that made the fixes visible: a refused tool call
reached the model as a success, a failed delegated run came back as an empty
answer, and the quota gate asks core. `CHANGELOG.md` has the operator-facing
list, one section per fix. `v0.1.12` names `c8e6878`, whose `pyproject.toml`
says `0.1.12`. It was the last release whose tail was written by hand. That
happened in REM-150's own PR, by running the script the workflow now runs.

0.1.13 to 0.2.5 have no paragraph here. Each is in the table, and
`CHANGELOG.md` has sections for 0.1.13, 0.2.0 and 0.2.1; nothing was written for
0.2.2 to 0.2.5, and nothing is reconstructed for them now.

0.2.6 exists for the LangGraph tour's fresh readers, who ran it against
extension 0.2.23. A router's catalogue was one list cached at sync, holding only
agents nobody owned, so a router whose writers were private or an org's could
not reach them (REM-971, #106); and a provider's refused key reached the worker
as a retryable 502, so an `agent:` step was retried five times before saying
nothing useful (REM-987, #107). `v0.2.6` names `23c813b`, whose
`pyproject.toml` says `0.2.6`. Its run (39314270944) published to PyPI and
Docker Hub and tagged, then its `publish` job failed checking out get-percolate
with `Bad credentials`. So the step that points the chart and the docs at
0.2.6 did not run, and get-percolate still names 0.2.5 until it does. The tail
on this repository (`b1b6bc8`) did land.

0.1.4 and 0.1.5 were tagged correctly and had no Release page; both were created
on 2026-09-12 and say so in their own text, so nobody reads a 2026-09-12
timestamp as the date the software shipped. 0.1.5 has no code change in it at
all — `git diff v0.1.4 v0.1.5` is the two version strings — which its page
records rather than dresses up.

## `v0.1.8` is off by one, and is not being moved

`v0.1.8` points at `8c03d2a`, whose tree says `0.1.7`. The commit that is
0.1.8 is `91ef61b`, its immediate child.

```
$ git show v0.1.8:pyproject.toml | sed -n 3p
version = "0.1.7"
$ git diff --stat v0.1.8 91ef61b
 percolate_core/__init__.py | 2 +-
 pyproject.toml             | 2 +-
```

That diff is the whole of it: two version strings and nothing else. The code
published as 0.1.8 is byte-for-byte what the tag points at, so a checkout of
`v0.1.8` reproduces the right software and misreports its own version number.

It happened because the `tag` job took `github.sha` — main as it stood when the
button was pressed — instead of the commit that was built. 0.1.8 was the first
release under the tag-last ordering, so it is the only one affected;
`v0.1.4`–`v0.1.7` are self-consistent. The cause is fixed in `release.yml`, and
the assertion above would now refuse this tag.

The tag stays where it is. Moving a published tag breaks every clone that has
already fetched it, and buys back two lines that this file already records.
