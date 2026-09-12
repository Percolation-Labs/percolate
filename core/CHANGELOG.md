# Changelog

**This file starts at 0.1.9.** Everything published before it shipped with no
notes, and saying so beats reconstructing nine releases from commit subjects
and presenting the guesses as a record. What *is*
known about the earlier tags is in [Released versions](#released-versions)
below, and every field there was read out of git or the GitHub API.

It exists because something depended on it and it did not:
`p8-subsystems/PACKAGING.md` made bumping the `percolate-core` pin conditional
on "the `percolate-core` release notes" — a precondition that had never been
met and could not be, so the bump happened without it. A condition nobody can
satisfy is not a safeguard; it is a sentence people learn to step over.

## 0.1.9

`pyproject.toml` said `0.1.9` with no `v0.1.9` tag, so the release workflow ran
in **retry** mode and published the tree as it stood rather than bumping again.

**Read this first if you run the extension at 0.2.0 or later.** 0.1.8 and
earlier cannot serve such a database *at all*: they set the caller's role
before writing the claims, and 0.2.0 refuses `pg_catalog.set_config` to
`authenticated`, so no turn opens a session and every one of them fails after
the service has reported healthy. **0.1.9 is the minimum runtime for a 0.2.0
database.** The pairing is not a preference — a database is refused the upgrade
to 0.2.0 while that grant is still there, so there is no 0.2.0 database without
the revoke.

Seventy commits since `v0.1.8`, 45 of them not merges, and this list is what
changes behaviour rather than all of them. The identity group is first because
it is why the release exists.

### Identity, and who a statement runs as

- **Claims are written before the role switch.** `core/identity.as_caller` set
  `role` and then the claims; the second statement is refused on a 0.2.0
  database. The order is now claims-then-role, which is PostgREST's order and
  the only one that works — the revoke exists because while `authenticated`
  could call `set_config`, any signed-in user could write another user's `sub`
  into `request.jwt.claims` from inside `aiq.sql_passthrough` and read as them.
- **An org-scoped token is no longer widened to every org.** The agent runtime
  verified tokens with a second, hand-written HS256 path that kept only `sub`,
  so a token carrying `orgs: [A]` reached the database with no `orgs` claim —
  which `rbac.current_org_ids()` reads as *every* org the user belongs to.
  One verifier now, shared with the Content Server.
- **A streamed turn no longer hands its connection back still as
  `authenticated`.** A pooled connection left in a caller's role is the next
  caller's identity.
- **A missing secret, a path parameter and an uploaded file each decided
  authority, and none of them may.** The gateway accepted an unverified
  `X-P8-User-Id` when `P8_JWT_SECRET` was unset (it now refuses to start
  unless `P8_DEV_NO_AUTH=1`); an OpenAPI path parameter could escape its
  operation; an uploaded file was served with a content type it chose.
- **A credential goes only to the origin it is bound to.** A tool server
  registered at a host of your choosing was a credential oracle, and the worker
  sent credentials to whatever host the row or upload beside them named.
- **The worker refuses its own egress to internal addresses** — it argued the
  database should not have egress while having it itself, including to
  `169.254.169.254`.
- **Row text from a fan-out is not resolved as a template.**

### A turn that finishes, and a pool that holds

- **A pool of eight served four conversations.** A turn holds one connection
  for its life and takes a second per query, so `pool_max` of 8 deadlocked at
  eight concurrent turns. The default is 16, the budget is documented, and an
  acquire that cannot be satisfied now says so instead of hanging.
- **A task longer than the lease finishes once.** `heartbeat_task` shipped, was
  granted to `worker`, and was called by nothing, so a five-minute task was
  reaped and re-run.
- **A runtime that cannot serve its database refuses at startup**, naming the
  remedy, instead of failing inside every turn behind an HTTP 200 that
  `docker compose ps` calls healthy.
- **A database refusal reaches the caller as 403**, not as a server error, on
  every endpoint — and the worker no longer retries one four times.
- **A provider account out of credit is classified, not retried.** It looked
  like a rate limit on three of the four paths that call a provider.
- **A delegation tree has a budget**, and a run that stopped because it ran out
  says so rather than chipping as nothing in particular.
- **A scheduled step's namespace exists.** The documented form named one that
  did not.
- **A summary is replayed as delimited user text, not as a system prompt** — a
  summary is a record of a conversation, not an instruction from the operator.

### Contracts, configuration and screens

- **One translation from an agent document to a row.** `packages/apply.py`,
  `core/samples.py` and `percolate agent push` each knew one dialect, so an
  agent written the documented way installed through the wrong loader with an
  empty prompt and no output contract, reporting success. `agent push` was the
  worst of the three: it parsed the document into an `AgentSpec` and dropped
  `audience` and `category` **in the client**, so a documented extractor
  installed as a `general` agent. All three now send the document, and the
  extension holds the single translation (needs percolate 0.2.0).
- **`authoring.from_json_schema` keeps `$defs`.** A nested model's contract used
  to store a `$ref` pointing at definitions nobody kept, so `agent show | agent
  push` did not round-trip.
- **A provider account out of credit is classified, not retried.** It looked
  like a rate limit on three of the four paths that call a provider, so an
  exhausted account was retried until something else failed.
- **The agent runtime speaks OpenTelemetry.** `percolate_core/agentic/telemetry.py`
  is new; the published image has no telemetry module.
- **The workbench** (`percolate ui`, the `[ui]` extra) is new.
- **One database and one object store, whoever is asking** — which service you
  are does not change where the data is.
- **Six assistants implemented one suggestion contract six ways**, and one of
  them proposed tools it then called. One contract now, and four screens stopped
  doing the database's arithmetic in JavaScript.
- **A lake worker refines staged data in DuckDB** and runs `p8ql` LAKE steps.
- **A release tag names the commit that was released.** `v0.1.8` named a tree
  that said `0.1.7`, and nothing said so anywhere.

Two `get-percolate` pages describe telemetry and the workbench as not yet
shipped — `docs/src/ui.md` ("the workbench is not in a published release yet …
`percolate-core` `@@core@@` on PyPI has no `ui` command and no `[ui]` extra")
and `docs/src/operating.md` ("the agent runtime speaks OpenTelemetry **from the
next `percolate-core` release**"). Both ship here, and `@@core@@` renders
whatever `versions.toml` pins — so those sentences renumber themselves into
lies: the number stays true and the claim goes false. Rewritten in gp#27, which
lands **after** this release and after the pin moves, because until then
`@@core@@` still renders 0.1.8 and the corrected sentence would be false in the
other direction.

`docs/src/skills.md` is NOT in that set and is unchanged: the runtime still
does not read `agents.skills` or `context_policy.skills`, so its sentence
survives 0.1.9.

## Released versions

Read from git and the GitHub API on 2026-09-12, not from memory.

| tag | commit | `pyproject` at that commit | date | GitHub Release |
|---|---|---|---|---|
| `v0.1.8` | `8c03d2aa` | **0.1.7** ← wrong, see below | 2026-09-06 | yes |
| `v0.1.7` | `939a5be6` | 0.1.7 | 2026-09-04 | yes |
| `v0.1.6` | `d8ae1508` | 0.1.6 | 2026-09-02 | yes |
| `v0.1.5` | `6669bc49` | 0.1.5 | 2026-09-02 | **none** |
| `v0.1.4` | `db0a9440` | 0.1.4 | 2026-09-02 | **none** |

`0.1.0`–`0.1.3` were published to PyPI with **no tag at all**, so there is no
commit this repository can point at for any of them. `0.1.1` was **yanked**.

### `v0.1.8` points at the wrong commit, and is being left alone

The tag names `8c03d2aa`, whose tree says `version = "0.1.7"`. The commit that
actually carries 0.1.8 is `91ef61b` (*"0.1.8: bump"*), and it is **not an
ancestor of its own tag**:

```
$ git merge-base --is-ancestor 91ef61b v0.1.8
NO
```

**Cause.** The `tag` job in `.github/workflows/release.yml` checked out with no
`ref:`, so it took `github.sha` — `main` as it stood when the button was
pressed — while `build` and `image` both used `needs.version.outputs.sha`. Two
of three jobs had it right. `v0.1.8` was the first release under the tag-last
ordering and the only one affected. Fixed in #12, which also refuses to tag
when the checked-out tree disagrees with the version being tagged.

**The artifact is believed correct and the tag is not.** The wheel and image
were built by jobs that used the right ref, so what is on PyPI as 0.1.8 should
be `91ef61b`'s tree. That is an inference from reading the workflow rather than
something checked against the published wheel, and it is labelled as one so the
next reader does not inherit it as a measurement.

**Decision: annotate, do not re-point.** Moving a published tag is the thing
this project refuses to do elsewhere — `get-percolate` records `.so` digests on
every image precisely so that a re-pointed tag is *detectable* — and moving one
inside the fix for a mis-tagging bug, without saying so, would undercut that. The tag is
wrong, nothing downstream consumed it as a build input, and a moved tag is a
second and much harder-to-see kind of wrong. So: `v0.1.8` stays where it is and
this paragraph is the correction. Anyone reproducing 0.1.8 wants `91ef61b`.

Reviewable later, and this is the record to review.

### `v0.1.4` and `v0.1.5` have no GitHub Release

Both tags exist and both versions are on PyPI; neither has a Release object, so
neither appears in `gh release list`. Left as they are — a Release created now
would carry today's date and auto-generated notes for work done in September,
which is a worse record than a gap somebody can see. Noted here so the absence
is a recorded fact rather than a thing somebody re-discovers.
