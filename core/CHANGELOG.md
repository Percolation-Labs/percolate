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

## Unreleased

Nothing yet. `pyproject.toml` says `0.1.9` and no `v0.1.9` tag exists, so the
release workflow treats 0.1.9 as a **retry** — it publishes the tree as it
stands rather than bumping again.

What is on `main` and not in published 0.1.8:

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
- **The workbench** (`percolate ui`, the `[ui]` extra) is new and unpublished.

Several documentation pages in `get-percolate` say "percolate-core `@@core@@`
does not yet ..." about the last two. Those sentences renumber themselves on
release — the number stays true and the claim goes false — so they need
rewriting with this release rather than after it.

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
