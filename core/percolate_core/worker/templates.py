"""Resolving {{steps.x.y}} / {{run.x}} / {{env.X}} in a task's input.

Resolution happens at DISPATCH, against the run context as it actually is --
never when the workflow is authored. Substituting at author time would make the
stored definition a snapshot of one run, break replay, and make the recorded
task input a lie about what was sent.

The database has its own resolver for `sql` steps (`workflow.resolve_args`),
deliberately narrower: no {{env.*}}, because the database has no business
reading the deployment's environment. This one has it, because credentials and
endpoints live here.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any

TEMPLATE = re.compile(r"\{\{\s*([a-zA-Z0-9_.\[\]]+)\s*\}\}")


class TerminalError(Exception):
    """A failure that will recur identically on every retry."""


def dig(obj: Any, path: str) -> Any:
    """Walk a dotted path, treating integer segments as list indices."""
    for part in path.split("."):
        if obj is None:
            return None
        if isinstance(obj, list):
            try:
                obj = obj[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(obj, dict):
            obj = obj.get(part)
        else:
            return None
    return obj


def resolve(value: Any, ctx: dict) -> Any:
    if isinstance(value, dict):
        return {k: resolve(v, ctx) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, ctx) for v in value]
    if not isinstance(value, str):
        return value

    sources = {"steps": ctx.get("context") or {}, "run": ctx.get("run_input") or {}}

    # A whole-string reference keeps its native type, so
    # body: "{{steps.x.result}}" sends an object rather than a JSON string
    # containing one.
    whole = TEMPLATE.fullmatch(value.strip())
    if whole:
        head, _, rest = whole.group(1).partition(".")
        if head in sources:
            found = dig(sources[head], rest)
            if found is None:
                raise TerminalError(f"template {{{{{whole.group(1)}}}}} resolved to nothing")
            return found

    def sub(m: re.Match) -> str:
        ref = m.group(1)
        head, _, rest = ref.partition(".")
        if head in sources:
            found = dig(sources[head], rest)
        elif head == "env":
            found = os.environ.get(rest)
        else:
            raise TerminalError(
                f"unknown template namespace '{head}' in {{{{{ref}}}}}"
                " -- expected steps, run or env")
        # Terminal, not retryable: a missing reference is a definition bug or a
        # missing env var, and no number of retries will conjure it.
        if found is None:
            raise TerminalError(f"template {{{{{ref}}}}} resolved to nothing")
        return found if isinstance(found, str) else json.dumps(found)

    return TEMPLATE.sub(sub, value)


# A fan-out child's own row, kept verbatim beside the substituted input
# (workflow-engine §20a-bis). It is DATA -- whatever was in the table or the
# uploaded document -- and is never a template.
ROW_KEYS = ("item", "items", "batch", "braces")


def restore_braces(value: Any, sentinel: str) -> Any:
    if isinstance(value, dict):
        return {k: restore_braces(v, sentinel) for k, v in value.items()}
    if isinstance(value, list):
        return [restore_braces(v, sentinel) for v in value]
    if isinstance(value, str):
        return value.replace(sentinel, "{")
    return value


def resolve_task(spec: dict, ctx: dict) -> dict:
    """Resolve a task's input in ONE pass over what its author wrote.

    A matrix child's input already carries its row's text, substituted by the
    database at expansion. Resolving that text again is how a transcript that
    quoted a workflow failed with `template {{env.LLM_URL}} resolved to
    nothing` -- and how `{{env.<secret>}}` in an uploaded document would have
    been sent to a model provider. So:

      * the database escapes every `{` in row text with a per-child sentinel,
        recorded as `braces`, and nothing in row text can open a template;
      * the row snapshot (`item`, `items`, `batch`) is not resolved at all;
      * after the one pass, the sentinel becomes `{` again, so the request
        carries the row's text exactly.

    An older database sends no sentinel and its row text is not escaped; an
    older worker sends the sentinel instead of `{`. Both halves are needed.
    """
    if not isinstance(spec, dict):
        return resolve(spec, ctx)
    sentinel = spec.get("braces") if isinstance(spec.get("braces"), str) else None
    out = {k: (v if k in ROW_KEYS else resolve(v, ctx)) for k, v in spec.items()}
    out.pop("braces", None)
    return restore_braces(out, sentinel) if sentinel else out
