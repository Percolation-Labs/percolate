# Ontology — the claims layer

Small on purpose. `schema.sql` will be the territory; this is the map.

```
                          supersedes
                        ┌──────────────┐
                        ▼              │
   ┌───────────┐   depends_on   ┌────────────┐   anchored_at   ┌──────────┐
   │  Claim    │◀──────────────▶│   Claim    │────────────────▶│  Symbol  │
   │           │                │            │                 │ (pg_proc,│
   │ assertion │                └────────────┘                 │  a file, │
   │ level     │                       ▲                        │ a table) │
   │ falsifier │                       │ exception_of           └──────────┘
   │ rationale │                ┌────────────┐                       ▲
   │ status    │                │ Exception  │                       │
   │ expiry    │                │ own expiry │                  radius of
   └───────────┘                └────────────┘                  a Diff
         │
         │ discharged_by                     ┌───────────────┐
         ▼                                   │   Falsifier   │
   ┌───────────┐                             │ registered fn │
   │ Discharge │────────────────────────────▶│ type + ref    │
   │ verdict   │                             └───────────────┘
   │ at        │
   └───────────┘
```

The decision half, which is the same graph approached from before the choice
rather than after it:

```
        constrains                              justifies
      ┌────────────┐                        ┌──────────────▶ Claim
      ▼            │                        │
 ┌──────────┐      │      ┌──────────┐      │
 │ Decision │──────┘      │  Option  │──────┘
 │ question │◀────────────│ chosen?  │
 │ evidence │   1 : many  │ plaus.   │       requires[] on the OPTION is what
 │ reversal │             │ c/r/v    │       `constrains` is derived from --
 │ status   │             │ why_not  │       stated where it is known, never
 └──────────┘             │ requires │       drawn afterwards.
                          └──────────┘
```

## Nodes

| node | one row per | key a person types | notes |
|---|---|---|---|
| `Claim` | a falsifiable assertion about the system | its id; the assertion is the label, not the key | a model, so a table, so an agent |
| `Exception` | a scoped, justified violation | claim + scope | **its own expiry**, independent of the claim |
| `Falsifier` | a registered way of checking | its registered name | `workflow.step_functions` already is this table |
| `Symbol` | a thing a claim can be anchored to | qualified name | already `aiq.nodes` for catalogue objects; files and code functions need the same treatment |
| `Discharge` | one activation of a falsifier against a claim | claim + run | append-only; the record of what was checked when |
| `Decision` | a choice where more than one option was live | `<area>.<slug>` | the rejected options are **rows**, so entropy is computed rather than authored — the decision model, kept in an internal application |
| `Option` | one alternative considered, including the one taken | decision + option | carries `plausibility`, `cost`, `risk`, `value`, `why_not`, and `requires[]` |

`Claim.level` is `symbol | module | service | system | policy` — the abstraction
the assertion is about, which is *not* the same as what it is anchored to. A
policy-level claim can be anchored to twenty symbols.

## Edges

| edge | kind | why it is first-class |
|---|---|---|
| `anchored_at` | claim → symbol | makes claim blast radius **computable**. Without it the whole design is a document store |
| `depends_on` | claim → claim | the thing spec-driven development lacks: criteria in a bag do not propagate, so a change invalidates one silently |
| `supersedes` | claim → claim | the query shape that beats vector memory. **Never a delete** — history is the asset |
| `exception_of` | exception → claim | so an exception can expire while the claim stands |
| `constrains` | decision → decision | **derived** from `Option.requires`, never drawn: the dependency is stated by the person weighing the option, at the moment they know it |
| `justifies` | decision → claim | the chosen option's premises are claims; this is where the two halves meet |

All six go in `aiq.relation_types`, which refuses an unlisted triple at write
time — so the vocabulary cannot accumulate typos-as-relations. The last two are
the decision half and only `constrains` is load-bearing today; `justifies` is
specified and unbuilt.

## The three vocabularies

Rows with foreign keys, not enums in a config file. Each carries what the term *means*, not just its
label:

- **`status`** — `proposed | active | superseded | expired | orphaned`, carrying
  `is_surfaceable` and `is_terminal`. An agent's write lands `proposed` and
  cannot reach `active` without a human or a passing falsifier.
- **`falsifier_type`** — `type | test | property | static_query | contract |
  runtime_assert | prose`, carrying `cost` and `rank`. Prose ranks last and
  requires an expiry; a type is already discharged and only its **exceptions**
  are persisted.
- **`provenance`** — `revert | fix | incident | review | adr | human`, carrying
  which extraction tier produced it.

## What is deliberately absent

**No `confidence` on an edge.** The source's Claim model carries one and it is a
number nothing here can currently fit against ground truth. A fitted weight is not eligible for core until an
instrument measures it against ground truth; `false_fires` is a count and can be carried today.

**No `Diff` node.** A diff is a stimulus, not a thing to remember. Its radius is
computed and thrown away; what persists is the `Discharge` rows it produced.

**No `depends_on` between two claims until it is tested against `constrains`.**
Two claims usually move together because one *decision* constrained both, so the
claim-to-claim edge loses the reason and pays n² edges for it. The decision is
the hub. `depends_on` stays in the design because the source specifies it;
the decision model is the thing to measure before Phase 3 commits.

**No line numbers anywhere.** A claim bound to a line is dead on the first
refactor, which is the whole of §8 of the brief.
