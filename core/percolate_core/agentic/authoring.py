"""Authoring an agent: one format, and it is a JSON Schema document.

``brief.md`` §6 says an agent can be authored in code, is "fully serializable
the moment it's finished", and is applied as a *migration* that upserts one row.
This module is both ends of that, and there is deliberately only one shape.

An agent **is** the flat schema document ``model_json_schema()`` produces, with
agent config beside the schema fields where ``json_schema_extra`` hoists it. The
convention is ``../p8k8``'s (``p8/agentic/agent_schema.py``) and it is worth
keeping precisely for what it rules out: there is **no ``prompt`` key**. The
system prompt is the schema's ``description`` — the *docstring of the model
class* — and the structured output is its ``properties``. So authoring in Python
and authoring in YAML produce the same document, byte for byte:

    class Support(BaseModel):
        '''You triage incident questions for the support desk.'''
        model_config = ConfigDict(json_schema_extra={
            "name": "support",
            "model": "openai:gpt-4.1-mini",
            "tools": [{"server": "p8-rag", "tools": ["post_rpc_search_chunks"]}],
        })
        claim: str

    Support.model_json_schema()   ==   yaml.safe_load(open("support.yaml"))

That is §6's "authored in code, deployed as data" as a fact rather than a
promise — ``from_model_class`` is one line because the pydantic model *already
is* the interchange format. It is a format like any other, but one that carries
more meaning: every tool that reads JSON Schema reads an agent, and the
description a human writes is the description a model receives.

A second, prose-shaped format lived here for a while, on the argument that a
reading form and a committing form answer different questions. It is gone: its
top-level key was ``prompt``, which is the one thing this convention says does
not exist, and a reading form that contradicts the deployed form teaches the
wrong shape. YAML with block scalars reads fine.

One deliberate divergence from p8k8, noted rather than silently inherited: it
distinguishes ``structured_output: true`` (properties are the output contract)
from ``false`` (properties are "thinking aides" that shape the model's reasoning
without being returned). This runtime has one meaning for ``properties`` — the
output contract, which is what makes ``chained_action`` reachable (``brief.md``
§2). Thinking aides are a real idea and simply are not built here.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from .contracts import AgentSpec, ChainedAction, ContextPolicy, ToolRef

# ---------------------------------------------------------------------------
# JSON Schema — the deployable form
# ---------------------------------------------------------------------------

def to_json_schema(agent: AgentSpec) -> dict[str, Any]:
    """An ``agents`` row as the flat schema document ``model_json_schema`` emits.

    Flat, not nested under ``json_schema_extra``: pydantic hoists that wrapper
    to the top level when it builds the schema, so a nested document here would
    not match what a code-authored agent produces — and matching is the whole
    point of the convention.
    """
    doc: dict[str, Any] = {"type": "object", "name": agent.name}
    if agent.system_prompt:
        doc["description"] = agent.system_prompt
    if agent.model:
        doc["model"] = agent.model
    if agent.tools:
        doc["tools"] = [t.model_dump(exclude_none=True) for t in agent.tools]

    schema = agent.structured_output_schema or {}
    doc["properties"] = schema.get("properties", {})
    if schema.get("required"):
        doc["required"] = schema["required"]
    # Back out at the top level, where pydantic puts them: a contract whose
    # properties hold a `$ref` needs its `$defs` in the same document or the
    # round trip -- `agent show` edited and pushed back -- emits a schema that
    # points at nothing.
    for key in ("$defs", "additionalProperties"):
        if schema.get(key) is not None:
            doc[key] = schema[key]

    if agent.chained_action:
        doc["chained_action"] = agent.chained_action.model_dump()
    if agent.summarizer_agent_id:
        doc["summarizer_agent_id"] = str(agent.summarizer_agent_id)
    policy = agent.context_policy.model_dump(exclude_none=True)
    if policy:
        doc["context_policy"] = policy
    return doc


def from_json_schema(doc: dict[str, Any]) -> AgentSpec:
    """The inverse: a schema document as the typed spec it describes.

    ``description`` is the system prompt and ``properties`` is the structured
    output — the two mappings that make "no ``prompt`` key" work. Everything
    else is agent config sitting at the same level, exactly where
    ``json_schema_extra`` puts it.

    **THIS IS NOT THE WRITE PATH** (``brief.md`` §6.1, REM-70). It exists so a
    document can become a typed object *in this process*, with no database
    anywhere — which is the whole of ``from_model_class`` and of the in-memory
    repository. A row that is really stored is translated by
    ``agentic.agent_document_to_row`` in the extension, because three loaders
    each holding their own version of this mapping is how the same extractor came
    to install differently depending on which tool applied it. So: parse a
    document for your own use, and send the *document* to the database.

    It is also lossier than the database's, necessarily and only in one
    direction: ``AgentSpec`` does not model ``category``, ``audience``, ``tags``,
    ``skills``, ``plugin`` or the scope columns, so those survive only by never
    being translated here.
    """
    properties = doc.get("properties") or {}
    output = (
        {
            "type": "object",
            "properties": properties,
            "required": doc.get("required", []),
        }
        if properties
        else None
    )
    # `$defs` TRAVELS WITH THE SCHEMA, because a nested pydantic model emits
    # `{"$ref": "#/$defs/Claim"}` into `properties` and the definitions beside
    # it. Dropped — which is what this did — the stored contract carries a `$ref`
    # pointing at nothing, and no provider can validate a response against it.
    # `agentic.agent_document_to_row` keeps it for the same reason; the two agree
    # on this document, which is asserted in `tests/smoke.py`.
    if output is not None:
        for key in ("$defs", "additionalProperties"):
            if doc.get(key) is not None:
                output[key] = doc[key]
    return AgentSpec(
        name=doc.get("name") or doc.get("title", ""),
        system_prompt=doc.get("description", ""),
        model=doc.get("model"),
        tools=[ToolRef(**t) for t in doc.get("tools", [])],
        structured_output_schema=output,
        chained_action=(
            ChainedAction(**doc["chained_action"]) if doc.get("chained_action") else None
        ),
        summarizer_agent_id=doc.get("summarizer_agent_id"),
        context_policy=ContextPolicy(**doc.get("context_policy", {})),
    )


def from_model_class(model_cls: type) -> AgentSpec:
    """A code-authored agent, deployed as data — and it really is three lines.

    The docstring is the prompt, the fields are the output, ``json_schema_extra``
    is the config. Nothing is extracted or inferred; pydantic already produces
    the interchange format.
    """
    return from_json_schema(model_cls.model_json_schema())


class _BlockDumper(yaml.SafeDumper):
    """Emit multi-line strings as block scalars.

    Cosmetic, and worth the six lines: the description *is* the system prompt —
    the part of an agent a human actually edits — and PyYAML's default folds it
    into quoted lines with blank rows between them, unreadable in a file whose
    whole purpose is to be read in a diff.
    """


def _block_str(dumper: yaml.SafeDumper, value: str) -> Any:
    return dumper.represent_scalar(
        "tag:yaml.org,2002:str", value, style="|" if "\n" in value else None
    )


_BlockDumper.add_representer(str, _block_str)


def to_yaml(agent: AgentSpec) -> str:
    """The schema document as YAML — exactly what ``agent push`` accepts back."""
    return yaml.dump(
        to_json_schema(agent), Dumper=_BlockDumper, sort_keys=False, width=88
    )


def load(path: Path | str, text: str | None = None) -> AgentSpec:
    """Read an agent definition from a file or a string.

    YAML and JSON are the same document to ``yaml.safe_load``, so there is
    nothing to dispatch on and no suffix to interpret.
    """
    body = text if text is not None else Path(path).read_text()
    return from_json_schema(yaml.safe_load(body))
