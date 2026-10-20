# Identity and nullability

**Status:** built and green, 2026-09-06. All four
steps of §8 are done, including step 4 — the `org_id` sentinel, which was the
decision this document was written to get a person to make. It was made in
favour of the sentinel org row (§4), and the shared tier is now
`rbac.shared_org_id()` = `f2999e5c-bccd-5883-a78a-65e124ca69d1`, derived rather
than invented.

Measured on a database built from these specs: **63 findings before, 0 after**,
and every gate `dev/check.sh` runs is green. `specs/identity/checks.sql` is now
one of them, and it carries a fifth assertion — no `org_id` anywhere is
nullable — so the seventeenth table cannot join without it.

Every table in this collection currently has one identity mechanism —
`gen_random_uuid()` — used 23 times, and one overloaded meaning of NULL used in
16 places. Neither was decided; both were inherited from the first table
somebody wrote. This document decides them, because the cost of getting
identity wrong scales with how much data is generated rather than typed, and
this system is built on the assumption that most of it will be generated.

## 1. Why this is urgent rather than tidy

A person creating a row does it once, notices a duplicate, and fixes it. A
worker re-ingesting a feed, an agent re-running a step, a loader rebuilt from
zero — each of those repeats an operation that was supposed to be idempotent,
thousands of times, and the only thing standing between that and a corrupt
corpus is whether the identity of a row is a **function of what it is** or an
accident of **when it was inserted**.

Three failures this collection has already had, all the same shape:

| | |
|---|---|
| `content.datasets` | `unique (org_id, name)` with a null org: `on conflict do update` matched nothing, and every upload inserted another `sales` |
| `content.channels` | the same shape, guarded by convention instead of a constraint. The first new caller used the ordinary idiom and created **five** identical channels in one session |
| an internal loader | primary keys built as `md5(natural_key)::uuid` so a rebuild would converge — which is the right instinct and the wrong construction, since that is not a UUID at all |

None was a hard bug. All three were a row's identity failing to be a function of
what the row is.

## 2. Every row has two identities, and they do different jobs

**A system id.** `id uuid primary key`, present on every table without
exception. It is what foreign keys reference, what an API returns, and what a
graph edge points at. It is never derived from user-supplied content, never
displayed as the primary way to name a thing, and never reused.

**A business unique, where one exists.** The natural key — `(channel_id,
external_id)`, `(org_id, name)`, a sha256 checksum — as its own `unique`
constraint. It is what an `on conflict` targets and what makes a repeated
operation converge. It is **not** the primary key, because natural keys change
and a primary key that changes takes every foreign key with it.

The rule that follows: **an upsert targets the business unique; a reference
targets the system id.** A table with no business unique is a table where
re-running an operation cannot be idempotent, and that has to be a deliberate
decision written down, not an omission.

## 3. Which UUID, and it is not one answer

PG19 ships `uuidv7()`, `uuidv4()`, `uuid_extract_timestamp()` and
`uuid_extract_version()` in `pg_catalog` — verified on 19beta3. So the choice
costs nothing to make and we are currently making the worse one 23 times.

**`uuidv7()` for rows the system creates.** Time-ordered, so inserts land at the
right-hand edge of the index instead of scattering across it, and
`uuid_extract_timestamp()` gives you creation time without a column. This is
the default and it should be the default everywhere `gen_random_uuid()` is
written today.

**A deterministic v5 for rows derived from something that already has an
identity.** A commit, a file path, a chunk of a document, an external record.
If the id is a function of the source, re-ingesting produces the same id, and
"did I already ingest this" stops being a query. That loader needed this and
reached for `md5(x)::uuid`, which produces a value with the version and variant
bits wrong — it is not a UUID, it will not compare equal to one generated
correctly elsewhere, and nothing would ever have told us.

PG19 has no native v5 and `uuid-ossp` is not in our manifest. It does not need
to be: v5 is SHA-1 over a namespace and a name with six bits overwritten, and
`pgcrypto` (already required) has `digest`. One function, in the extension, so
a client that has never heard of our Python can compute the same id:

```sql
percolate.uuidv5(namespace uuid, name text) returns uuid
```

**Never a bare hash cast to `uuid`.** It looks identical in `psql` and is not
the same value.

**Never `uuidv4()`/`gen_random_uuid()` for a primary key**, unless the row is
genuinely unordered and unreferenced.

## 4. NULL means unknown. It never means a value.

This is the deep one and it is why §1's failures were confusing rather than
obvious.

The collection uses NULL in two incompatible ways and **a reader cannot tell
which is which from the schema**:

| Column | NULL meant | Correct index behaviour |
|---|---|---|
| `org_id` (16 tables) | **shared across every tenant** — a value | `nulls not distinct` |
| `external_id` (`content.resources`, `workflow.runs`) | **no external identity was supplied** — an absence | `nulls distinct` |

The first row of that table is history: `org_id` is `NOT NULL` now. What
follows is the argument that made it so, kept because the *rule* generalises
and the next column to fail it will fail it the same way.

Both appear inside `unique` constraints. Both look the same. One of them is a
sentinel — a value wearing an absence's clothes — and it is the one that has
caused every duplicate this collection has had, because a unique index does not
constrain rows whose key is NULL and that is *correct behaviour* for an absence.

**The rule: a NULL may only mean "unknown or not applicable".** If a state is a
value, it gets a value.

For `org_id` that meant one of two migrations, and the choice was:

- **A sentinel org row.** ✅ **Taken.** `rbac.orgs` gains a well-known row for
  the shared tier; `org_id` becomes `not null` everywhere and every policy
  compares against a value. Uniform, and every existing `org_id is null`
  predicate in RLS had to be rewritten.
- **An explicit scope column.** `scope` (`'shared' | 'org'`) beside a nullable
  `org_id`, with a check that ties them together. Smaller change, and it leaves
  two columns that must agree — which is the shape this collection already
  regrets once: `ai-query-layer/integration-rbac.sql` records
  `node_keys.org_id` drifting from `nodes.org_id` and LOOKUP returning nothing
  while reporting no such key. The smaller change was the one that buys a
  future bug.

### What the sentinel is

```sql
rbac.shared_org_id() = percolate.uuidv5(percolate.id_namespace('org'), 'shared')
                     = f2999e5c-bccd-5883-a78a-65e124ca69d1
```

**Derived, not invented**, which is the whole reason it is safe to hard-code
predicates against: it is a pure function of two published strings, so it is
the same value in every deployment, computable by a client that has never
connected to one, and there is nothing for two installs to disagree about. A
`uuidv7()` default here would have made the shared tier deployment-local and
turned every fixture into a lookup.

Three functions and one migration primitive carry it, and no more:

| | |
|---|---|
| `rbac.shared_org_id()` | names it. Immutable and argument-free, so a policy folds it to a literal at plan time |
| `rbac.org_or_shared(uuid)` | coerces an **omitted argument** into it. Every writer takes `p_org_id uuid default null`, and an omitted parameter is a genuine absence — this is the one seam where an absence legitimately becomes a value, and it happens once per writer rather than once per insert |
| `rbac.is_shared_org(uuid)` | tests for it. The replacement for every `org_id is null` in a function body |
| `rbac.adopt_shared_org(regclass)` | the migration: `set default`, backfill, `set not null`, **in that order**. `add_scope_columns()` calls it, so fourteen of the sixteen get it for free; `aiq.node_keys` and `aiq.edges` ask by hand because they carry `org_id` without adopting scope |

**Nobody is a member of the shared org**, enforced by a `CHECK` on
`rbac.org_members`. That constraint is what lets `scope_predicate()` say
nothing at all about the sentinel and still be right: `visibility = 'org' and
org_id in (select rbac.current_org_ids())` can never admit a shared-tier row,
because the sentinel can never be in that set. Without the constraint the rule
holds until somebody inserts one row, which is a fact living one layer above
where it can be refused.

**The `nulls not distinct` flags stay, as no-ops with comments.** Five unique
indexes (`content.channels`, `content.datasets`, `aiq.node_keys`,
`aiq.lake_nodes`, `aiq.soft_nodes`) carry it. On a `NOT NULL` column it decides
nothing. Dropping it would rebuild a unique index on every deployment to change
nothing; leaving it silent would make the next reader work out from scratch
whether it is load-bearing. So each one says, where it is defined, that it is
not — and that anything making `org_id` nullable again makes it so.

**The rule that survives:** every unique index containing a nullable column
that means a *value* is `nulls not distinct`, and every one containing a
nullable column that means an *absence* stays `nulls distinct` — and the
difference is asserted rather than remembered (§7).

## 5. A label is never an identity

`title`, `heading`, a function's bare name, a display key. These are for people
to read and they are not unique, because the world is not unique:

- `rbac.current_org_ids` has **three overloads** and one name.
- Two spec sections in one file are both headed `run it`.

Both of those stopped work once, because something had unique-constrained
a label. A projection that needs a stable addressable key derives one; it does
not demand that the label be one.

## 6. Idempotency keys must be total

`content.register_fetched` is idempotent via `on conflict (channel_id,
external_id) do nothing`. `external_id` is nullable. **A puller that does not
supply one duplicates its whole backlog on every poll and nothing raises.**
`workflow.runs.external_id` is the same shape.

The constraint is *correct* — NULL there is a genuine absence — which is why
this is a design rule and not a bug fix: **a function whose contract is "safe to
re-run" must refuse the call when the key that makes it safe is missing**,
rather than accepting it and silently losing the guarantee.

## 7. The checks, because a policy nobody can fail is a preference

Five catalogue assertions, in `checks.sql`, in `dev/check.sh`:

1. Every table in a percolate schema has a `uuid` primary key named `id`.
2. No primary key defaults to `gen_random_uuid()` / `uuidv4()`.
3. Every unique index containing a nullable column declares its intent — the
   column is registered in `percolate.null_means` as `value` or `absence`, and
   `indnullsnotdistinct` agrees with it.
4. No shipped function derives an id with a bare hash cast.
5. No `org_id` is nullable, and every one defaults to `rbac.shared_org_id()`.

Check 5 is the only one that asserts an *answer* rather than demanding a
declaration, and it can because §4 decided the answer. It exists because the
sixteen columns arrive by two different routes — fourteen through
`rbac.add_scope_columns()`, two by hand — and a seventeenth added by somebody
who has read neither would otherwise show up as a duplicate row months later
rather than as a red gate the same afternoon. Made to fail on purpose by
dropping the `NOT NULL` from `content.channels`: it names that table, and check
3 fires alongside it because the column is nullable inside a unique index again.

Check 3 is the one that carries the policy: it does not decide what a NULL
means, it refuses to let the schema stay silent about it.

### Four things the first draft of these checks got wrong

Worth keeping, because each was a check firing on correct work, which is how a
gate gets switched off rather than fixed.

**"Every table has a uuid id" fired 28 times and the first twenty were right.**
A vocabulary keyed by its term, a junction keyed by its foreign keys, an
append-only log keyed by a bigint — all correct, and a surrogate in any of them
is ceremony. Hence `percolate.table_kinds`: the policy is per kind, and the
kind is declared. A fifth kind, `natural`, was added when `aiq.node_keys` and
`aiq.schema_revisions` turned out to be neither junction nor vocabulary.

**The proposal guessed rather than abstained.** Its fallthrough was `entity`,
so it confidently mis-proposed those same two tables and a reviewer accepted
them in bulk. It now returns null for a shape it does not recognise. A
proposal that is confident about what it does not understand is worse than one
that says nothing.

**The hash-cast check matched its own explanatory comment.** `md5(...)::uuid`
appears in the note documenting the fix, inside the function that had already
been corrected. It now strips `--` comments before scanning: a source-scanning
check that cannot tell code from commentary reports the remedy as the defect.

**A default changed in the spec is a no-op on an upgraded database.** The
generated upgrade is idempotent DDL and `create table if not exists` does not
alter an existing column's default, so a fresh install and an upgraded one
disagreed on 25 defaults. `dev/upgrade-converges.sh` caught it. The fix is a
rule over the catalogue in `declarations.sql` rather than 25 ALTER statements a
26th table would not join.

## 8. Migration

Pre-1.0, so old callers may break and the right answer is the right shape.
Order matters:

1. `percolate.uuidv5()` ships. Nothing depends on it yet.
2. PK defaults move `gen_random_uuid()` → `uuidv7()`. Existing rows keep their
   ids; only new rows are ordered. No data migration.
3. `percolate.null_means` is populated, and check 3 turns on. This is where the
   16 `org_id` columns get classified and the four indexes that disagree get
   fixed.
4. ✅ The `org_id` sentinel decision lands, and `org_id` becomes `not null`. The
   big one, and it is a `user-rbac` change with RLS consequences across all
   five subsystems.

Steps 1–3 were a day and broke nothing. Step 4 was the real work.

### What step 4 actually cost, since the estimate above was a guess

Five things, and four of them are the *boundaries* rather than the column:

- **The column itself was the easy part.** One function
  (`rbac.adopt_shared_org`), called from one place for fourteen tables and by
  hand for two.
- **Every writer's optional `p_org_id` stayed nullable**, and had to. An
  omitted argument is an absence — exactly what §4 reserves NULL for — so the
  translation to the shared tier happens at eleven call sites through
  `rbac.org_or_shared()`. This is the awkward shape the sentinel forces: the
  column is total and the API is not, and the seam between them is real work
  that a `scope` column would also have had, differently.
- **`aiq.register_entity_table()` projects from tables this collection does not
  own.** A customer's `org_id` is nullable and always will be, so the
  projection coalesces on the way in. The `NOT NULL` guarantee stops at the
  registry boundary by construction.
- **The policy text needed a GRANT.** `rbac.shared_org_id()` appears inside
  generated `WITH CHECK` expressions, and a policy is evaluated as the
  *caller*. Without `grant execute ... to authenticated`, the write policy
  raised permission-denied inside the check and `dev/tests/rbac/11` reported it
  as the two homes of the write rule disagreeing about a row — a true statement
  naming the wrong cause. Found only by running the check from a caller's seat;
  as `app_owner` it passed.
- **The partial index `where org_id is not null` became a lie.** It selects
  every row on a `NOT NULL` column, and `create index if not exists` matches on
  the name — so a fresh install would build the plain index and an upgraded one
  would keep the partial. `dev/upgrade-converges.sh` compares `indexdef`, which
  is the only thing in the repository that would have seen it, so
  `add_scope_columns()` drops the partial one by name before recreating.
