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

STEP_KINDS = ("sql", "sources", "graph", "plugin", "workflows", "documents")


class SampleError(RuntimeError):
    """The sample cannot be applied. Raised before anything is written."""


def _yaml() -> Any:
    try:
        import yaml
    except ModuleNotFoundError as err:  # pragma: no cover - depends on install
        raise SampleError(
            "reading a sample needs PyYAML: pip install 'percolate-core[agent]' "
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
        # Looked up rather than ON CONFLICT: the unique constraint is
        # (org_id, name) and org_id is nullable, so under the default NULLS
        # DISTINCT two shared channels of the same name do not conflict --
        # ON CONFLICT would insert a duplicate on every load rather than
        # matching the existing row.
        exists = await conn.fetchval(
            "select 1 from content.channels where name = $1"
            "   and org_id is not distinct from $2",
            c["name"], c.get("org"),
        )
        if not exists:
            await conn.execute(
                "insert into content.channels (name, kind, org_id) values ($1,$2,$3)",
                c["name"], c.get("kind", "manual"), c.get("org"),
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


def _agent_to_row(entry: dict[str, Any]) -> dict[str, Any]:
    """An agent written as a JSON Schema document, in the row shape.

    THE TWO DIALECTS LOOK ALIKE AND ONE IS SILENTLY DROPPED. Every page of the
    documentation authors an agent as a schema document -- the system prompt is
    `description`, the output contract is `properties` -- because that is the
    form a pydantic class already produces. `agentic.upsert_agent` takes the
    ROW, where those two are `system_prompt` and `structured_output_schema`,
    and ignores keys it does not know. So applying the documented form directly
    returns success and stores an agent with an empty prompt and no output
    contract: it exists, it resolves by name, and it can do nothing. That is
    the exact failure agents.md describes for a partial upsert, reached by a
    different road.

    `authoring.from_json_schema` is the canonical translation and this calls
    it rather than repeating the mapping -- two implementations of one
    convention is how they drift.
    """
    if "system_prompt" in entry or "structured_output_schema" in entry:
        return entry  # already the row shape; take the author at their word
    if not ({"description", "properties"} & entry.keys()):
        return entry  # neither dialect's distinguishing keys -- nothing to do

    try:
        from ..agentic import authoring
    except ModuleNotFoundError as err:
        raise SampleError(
            "this sample writes agents as JSON Schema documents, which needs "
            "the agent extra to translate: pip install 'percolate-core[agent]' "
            "(the published image already has it)"
        ) from err

    spec = authoring.from_json_schema(entry)
    row = spec.model_dump(mode="json", exclude={"id", "created_at", "updated_at"})
    # Keys the schema document carries that AgentSpec does not model, kept
    # rather than dropped -- `skills` and `category` are real columns.
    for extra in ("skills", "category", "audience", "tags", "plugin"):
        if entry.get(extra) is not None:
            row[extra] = entry[extra]
    return {k: v for k, v in row.items() if v is not None}


async def apply_plugin(conn: Any, doc: dict[str, Any]) -> list[str]:
    """Tool servers, skills and agents, as one named and removable bundle.

    `agentic.apply_plugin` already does this and does it in the right order --
    servers before skills before agents, because a skill can require a server
    and an agent can pin a skill. Reimplementing the ordering here would be a
    second place for it to be wrong. The agents are translated on the way in;
    see `_agent_to_row`.
    """
    doc = dict(doc)
    if doc.get("agents"):
        doc["agents"] = [_agent_to_row(a) for a in doc["agents"]]
    await conn.execute("select agentic.apply_plugin($1::jsonb)", json.dumps(doc))
    return [
        f"plugin {doc.get('name')} "
        f"({len(doc.get('tool_servers') or [])} servers, "
        f"{len(doc.get('skills') or [])} skills, "
        f"{len(doc.get('agents') or [])} agents)"
    ]


async def apply_workflows(conn: Any, paths: list[Path]) -> list[str]:
    done = []
    for p in sorted(paths):
        await conn.execute("select workflow.define_yaml($1)", p.read_text())
        done.append(f"workflow {p.stem}")
    return done
