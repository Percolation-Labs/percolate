"""Loading a sample: a directory of YAML, applied in a declared order.

A new install is empty, and almost every worked example in the documentation
reads data. So there has to be a way to *get* data — and the two obvious ways
are both wrong. Seeding on first boot makes a demo indistinguishable from a
deployment and leaves rows nobody chose. Shipping a `.sql` dump makes the
sample opaque: a reader cannot see that an agent is a row, because the row
arrives as an INSERT among four hundred others.

So a sample is a directory of the same documents you would author by hand —
an agent is the JSON Schema document `agents.md` describes, a workflow is the
YAML `define_yaml` compiles, a source is the registration call spelled out —
plus a manifest saying what order to apply them in. Loading it is a step the
reader takes on purpose, and reading it teaches the formats.

    percolate sample load samples/harbour

THE VECTORS ARE NOT IN THE FILES, and that is the point of the documents
directory. An earlier fixture shipped literal four-dimension vectors so it
would load with nothing running; it reproduced beautifully and taught the
wrong thing, because a reader who copies it has a corpus that no model
produced and rankings that mean nothing. Here the documents are markdown, they
go in through `POST /files` like anyone's would, and the ingestion pipeline
embeds them with the model the sample registers. That needs a real key. A
sample that needs a key is honest about what retrieval costs; one that does not
is a demonstration of a different system.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import agent_document

STEP_KINDS = ("sql", "sources", "graph", "plugin", "workflows", "documents")


class SampleError(RuntimeError):
    """The sample cannot be applied. Raised before anything is written."""


def _yaml() -> Any:
    try:
        import yaml
    except ModuleNotFoundError as err:  # pragma: no cover - depends on install
        raise SampleError(
            "reading a sample needs PyYAML: pip install 'percolate-core[sample]' "
            "(the published image already has it)"
        ) from err
    return yaml


def read_manifest(root: Path) -> dict[str, Any]:
    """Parse and check `manifest.yaml`, before touching the database.

    Everything checkable is checked here rather than mid-load: a sample that
    fails on its fourth step leaves three steps' worth of rows behind, and
    "partially loaded" is the one state neither loading again nor removing
    handles well.
    """
    path = root / "manifest.yaml"
    if not path.exists():
        raise SampleError(f"{path} does not exist -- a sample is a directory with a manifest")
    doc = _yaml().safe_load(path.read_text()) or {}
    if not doc.get("name"):
        raise SampleError(f"{path}: a sample needs a name -- it is what removing it later refers to")
    steps = doc.get("load") or []
    if not steps:
        raise SampleError(f"{path}: `load:` is empty, so this sample would do nothing")
    for i, step in enumerate(steps, 1):
        if not isinstance(step, dict) or len(step) != 1:
            raise SampleError(f"{path}: step {i} should be a single `kind: path` pair")
        kind, target = next(iter(step.items()))
        if kind not in STEP_KINDS:
            raise SampleError(
                f"{path}: step {i} is '{kind}', which is not one of {', '.join(STEP_KINDS)}"
            )
        if not (root / target).exists():
            raise SampleError(f"{path}: step {i} names {target}, which does not exist")
    return doc


async def assert_can_load(conn: Any, root: Path, manifest: dict[str, Any]) -> None:
    """Fail BEFORE the first write if this database would drop half an agent.

    The check this replaces asked whether the *agent extra* was installed,
    because the translation used to happen in this process (REM-70). It does not
    any more -- `agentic.upsert_agent` translates, so the documents go through
    untouched and the extra is not needed to load a sample at all. What is needed
    is an extension new enough to translate, and an older one accepts the
    document and stores an agent with an empty prompt, which is exactly the
    silence the fix removed.

    It stays a pre-flight for the reason the old one did. Asked at the agent
    step, a refusal leaves the schema, the entities, the graph and its edges
    written -- "partially loaded", the one state neither loading again nor
    removing handles well, produced by the loader itself.
    """
    for step in manifest.get("load") or []:
        kind, target = next(iter(step.items()))
        if kind != "plugin":
            continue
        try:
            doc = _yaml().safe_load((root / target).read_text()) or {}
        except Exception as err:
            raise SampleError(f"{root / target}: cannot be parsed as YAML ({err})") from err
        await agent_document.assert_translates(
            conn, doc.get("agents") or [], str(root / target)
        )


def missing_credentials(doc: dict[str, Any], env: dict[str, str]) -> list[str]:
    """Which declared credentials are absent from this environment.

    Returned rather than raised so the caller can report all of them at once,
    and so `--dry-run` can say what a real load would need.
    """
    wanted = (doc.get("requires") or {}).get("credentials") or []
    return [name for name in wanted if not env.get(name)]


# ---------------------------------------------------------------------------
# The steps. Each takes an open asyncpg connection and the parsed document, and
# each is idempotent -- a sample you cannot load twice is a sample you cannot
# fix a typo in.
# ---------------------------------------------------------------------------


async def apply_sources(conn: Any, doc: dict[str, Any]) -> list[str]:
    """Embedding models, entity tables, and the keys people actually type."""
    done: list[str] = []

    for m in doc.get("embedding_models") or []:
        await conn.execute(
            "insert into aiq.embedding_models"
            " (name, dim, provider, endpoint, credential_ref, is_default)"
            " values ($1,$2,$3,$4,$5,$6) on conflict (name) do update"
            "   set dim = excluded.dim, provider = excluded.provider,"
            "       endpoint = excluded.endpoint,"
            "       credential_ref = excluded.credential_ref",
            m["name"], m["dim"], m["provider"], m["endpoint"],
            m.get("credential_ref", "LLM_API_KEY"), bool(m.get("is_default")),
        )
        # The vector table is generated FROM the registry row, so this has to
        # follow the insert and cannot be folded into it.
        await conn.execute("select aiq.register_embedding_space($1)", m["name"])
        done.append(f"embedding model {m['name']} ({m['dim']}d)")

    # THE PIPELINE THAT USES THE MODEL, which registering the model does not
    # install. A fresh database already has an `ingest_file` definition -- the
    # extension's own bootstrap calls install_ingest_workflow() with no
    # argument, which is the PARSE-ONLY pipeline, so that a channel never
    # points at a definition that does not exist. Registering an embedding
    # model does not change it. Without this a sample's corpus parses, chunks,
    # and is never embedded: SEMANTIC and SEARCH find nothing, and no step ever
    # fails to say why.
    for ing in doc.get("ingest_pipelines") or []:
        msg = await conn.fetchval(
            "select content.install_ingest_workflow($1,$2,$3,$4)",
            ing.get("model"), ing.get("queue", "ingest"),
            ing.get("name", "ingest_file"), bool(ing.get("graph_index")),
        )
        done.append(f"ingest pipeline {msg}")

    for e in doc.get("entities") or []:
        await conn.execute(
            "select aiq.register_entity_table($1,$2,$3,$4,$5,$6)",
            e["entity_type"], e["source_table"], e["key_expr"],
            e.get("summary_expr", "null"), e.get("org_expr", "null"),
            e.get("include_where", "true"),
        )
        # Registration describes the projection; rebuild runs it. Without this
        # the registry is correct and empty, which looks like a broken LOOKUP.
        await conn.execute("select aiq.rebuild_entity_type($1)", e["entity_type"])
        done.append(f"entity {e['entity_type']} <- {e['source_table']}")

    for src in doc.get("lexical_sources") or []:
        await conn.execute(
            "select aiq.register_lexical_source($1,$2,$3,$4)",
            src["name"], src["source_table"],
            src.get("content_col", "content"), src.get("regconfig", "english"),
        )
        done.append(f"lexical source {src['name']}")

    for c in doc.get("channels") or []:
        # AN OMITTED `org:` IS THE SHARED TIER, AND THAT IS NOW A ROW RATHER
        # THAN A NULL. This read `org_id is not distinct from $2` and passed
        # `$2` straight into the column, both correct while org_id was
        # nullable and the shared tier was the absence of a value.
        # identity/spec.md §4 made it `rbac.shared_org_id()`: the column is
        # NOT NULL with that as its DEFAULT, and an explicitly passed NULL is
        # not defaulted -- it is refused.
        #
        #   null value in column "org_id" of relation "channels"
        #   violates not-null constraint
        #
        # samples/harbour/sources.yaml declares its channel with no `org:`, so
        # `sample load` -- the command install.md tells a reader to run --
        # dies here on any database carrying that constraint, after tenants.sql
        # and schema.sql have already written, which is the partially-loaded
        # state read_manifest exists to prevent. It has not bitten yet only
        # because the published image still has the old nullable column, and
        # that is also why ci/coldstart.sh cannot see it: it runs this command
        # against the published artifact, where the defect cannot occur.
        #
        # Looked up rather than ON CONFLICT for the original reason, which the
        # NOT NULL does not change: matching the existing row is what makes a
        # second load a no-op instead of a duplicate.
        #
        # AND ON EITHER SCHEMA. A published extension older than the shared-org
        # row has no rbac.shared_org_id() and keeps the shared tier as NULL, so
        # naming the function outright failed this step with
        # `function rbac.shared_org_id() does not exist` against the image
        # install.md pins -- a CLI newer than the database it is pointed at,
        # which pip produces by default. Resolved once, then compared with
        # IS NOT DISTINCT FROM, which reads a NULL and a row id the same way.
        shared = await conn.fetchval(
            "select case when to_regprocedure('rbac.shared_org_id()') is not null"
            " then 'shared' end")
        if shared:
            shared = await conn.fetchval("select rbac.shared_org_id()::text")
        exists = await conn.fetchval(
            "select 1 from content.channels where name = $1"
            "   and org_id is not distinct from coalesce($2::uuid, $3::uuid)",
            c["name"], c.get("org"), shared,
        )
        if not exists:
            # The column is OMITTED when the document omits it, so the DEFAULT
            # applies. Writing coalesce(...) here instead would put the name of
            # the shared tier in a second place; the default is already the one
            # place it is written down.
            #
            # OWNER AND VISIBILITY ARE WRITTEN, and leaving them to the column
            # defaults is the fourth instance of one defect. `private` with a
            # null owner means readable by nobody -- `rbac.may_read(null,
            # shared_org, 'private')` is NULL -- and 0.2.0 added
            # `channels_readable_by_somebody` to refuse exactly that row. So
            # `sample load`, the command install.md tells a reader to run, died
            # with `new row for relation "channels" violates check constraint`
            # the moment the published extension became one that carries the
            # CHECK. REM-147.
            #
            # The same call the fixed loaders make -- `percolate.apply_package`
            # both branches, `content.register_upload` -- rather than a literal,
            # because the answer differs by who is installing: this runs on
            # `P8_ADMIN_DSN`, so `rbac.is_operator()` is true and the channel is
            # `public` with no owner, which is what deployment configuration
            # should be. A signed-in installer gets `private` against their own
            # id. A constant would be right for one of them.
            #
            # Guarded by `to_regprocedure` for the reason the shared-org lookup
            # above is: a CLI newer than the database it is pointed at is what
            # pip produces by default, and an extension predating REM-83 has
            # neither the function nor the CHECK.
            vis = await conn.fetchval(
                "select case when to_regprocedure('rbac.default_visibility(uuid)')"
                " is not null then 1 end")
            cols, vals = ["name", "kind"], ["$1", "$2"]
            args = [c["name"], c.get("kind", "manual")]
            if c.get("org") is not None:
                cols.append("org_id")
                vals.append(f"${len(args) + 1}")
                args.append(c["org"])
            if vis:
                cols += ["owner_id", "visibility"]
                vals += ["rbac.current_user_id()", "rbac.default_visibility()"]
            await conn.execute(
                f"insert into content.channels ({', '.join(cols)})"
                f" values ({', '.join(vals)})", *args,
            )
        done.append(f"channel {c['name']}" + ("" if not exists else " (existed)"))

    for k in doc.get("node_keys") or []:
        await conn.execute(
            "select aiq.add_node_key($1,$2,$3)", k["node"], k["key"], k.get("kind", "alias")
        )
        done.append(f"key {k['key']} -> {k['node']}")

    return done


async def apply_graph(conn: Any, doc: dict[str, Any]) -> list[str]:
    """The relation catalogue, then edges named by key rather than by uuid.

    Edges reference nodes the way a person would -- `vessel:Meridian Dawn` --
    and this resolves them through `aiq.node_keys`. A fixture full of literal
    uuids is unreadable and, worse, unwritable: nobody can add an edge to it
    without first going and looking one up.
    """
    done: list[str] = []

    for r in doc.get("relations") or []:
        await conn.execute(
            "insert into aiq.relation_types"
            " (src_type, relation, dst_type, inverse_label, description)"
            " values ($1,$2,$3,$4,$5)"
            " on conflict (src_type, relation, dst_type) do update"
            "   set inverse_label = excluded.inverse_label,"
            "       description = excluded.description",
            r["src_type"], r["relation"], r["dst_type"],
            r.get("inverse_label"), r.get("description"),
        )
        done.append(f"relation {r['src_type']} -{r['relation']}-> {r['dst_type']}")

    async def node_id(ref: str) -> str:
        try:
            entity_type, key = ref.split(":", 1)
        except ValueError:
            raise SampleError(f"edge endpoint {ref!r} should be 'entity_type:key'")
        found = await conn.fetchval(
            "select node_id from aiq.node_keys"
            " where entity_type = $1 and lower(key) = lower($2)"
            " order by (kind = 'canonical') desc limit 1",
            entity_type, key,
        )
        if found is None:
            raise SampleError(
                f"no {entity_type} keyed {key!r} -- the sources step registers and "
                f"rebuilds the entity types, so it has to run before the graph step"
            )
        return found

    for e in doc.get("edges") or []:
        await conn.execute(
            "insert into aiq.edges (src_id, dst_id, relation, weight, provenance, org_id)"
            " values ($1,$2,$3,$4,$5,$6)"
            " on conflict (src_id, dst_id, relation) do update"
            "   set weight = excluded.weight, provenance = excluded.provenance",
            await node_id(e["src"]), await node_id(e["dst"]), e["relation"],
            float(e.get("weight", 1.0)),
            json.dumps(e.get("provenance") or {}),
            e.get("org"),
        )
        done.append(f"edge {e['src']} -{e['relation']}-> {e['dst']}")

    return done


async def apply_plugin(conn: Any, doc: dict[str, Any]) -> list[str]:
    """Tool servers, skills and agents, as one named and removable bundle.

    `agentic.apply_plugin` already does this and does it in the right order --
    servers before skills before agents, because a skill can require a server
    and an agent can pin a skill. Reimplementing the ordering here would be a
    second place for it to be wrong.

    AND THE AGENTS GO THROUGH EXACTLY AS WRITTEN. This function used to translate
    them -- a schema document's `description` and `properties` onto the row's
    `system_prompt` and `structured_output_schema` -- because `upsert_agent` read
    only the row keys and dropped the rest in silence. Three loaders did that,
    each knowing one dialect, which is REM-70: `p8-subsystems/packages/apply.py`
    knew a package's file-path `output_schema` and not this one, so the same
    extractor installed differently depending on which tool applied it, and a
    package manifest written the documented way installed an agent with no prompt
    and reported success.

    The translation is `agentic.agent_document_to_row` now, called by
    `upsert_agent`, so both documented forms install the same row through every
    tool there is and a key nobody reads is refused rather than dropped. The only
    thing left for a client to know is whether the database is new enough to do
    it, which `assert_can_load` asks once, before the first write.
    """
    doc = dict(doc)
    await conn.execute("select agentic.apply_plugin($1::jsonb)", json.dumps(doc))
    return [
        f"plugin {doc.get('name')} "
        f"({len(doc.get('tool_servers') or [])} servers, "
        f"{len(doc.get('skills') or [])} skills, "
        f"{len(doc.get('agents') or [])} agents)"
    ]


def orgs_in_documents(where: Path, yaml: Any) -> list[str]:
    """Every distinct org the documents index names, in order.

    Read separately from the upload loop because the TOKEN has to be minted
    before the first request, and it has to cover all of them: the Content
    Server checks the caller's claims per upload, so a token good for the first
    document fails on the third.
    """
    index_path = where / "index.yaml"
    if not index_path.exists():
        return []
    entries = yaml.safe_load(index_path.read_text()) or []
    seen: list[str] = []
    for e in entries:
        org = e.get("org")
        if org and org not in seen:
            seen.append(org)
    return seen


async def apply_workflows(conn: Any, paths: list[Path]) -> list[str]:
    done = []
    for p in sorted(paths):
        await conn.execute("select workflow.define_yaml($1)", p.read_text())
        done.append(f"workflow {p.stem}")
    return done
