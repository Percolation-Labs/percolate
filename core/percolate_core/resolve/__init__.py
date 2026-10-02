"""The resolver: candidates the extractor could not resolve, decided by Jev.

    percolate resolve serve --queue resolve

Laid out as `ingest` is: this module is the work, `handler` registers the
`work` step and is imported only by `serve`, and `cli` is what the top-level
command mounts -- so starting any other worker never registers this one.

`aiq.upsert_graph` lands every name it cannot match exactly as a soft node.
This worker takes a page of them, asks the database what each could be
(`aiq.resolution_candidates`: trigram proposals of the target type, never a
pair already decided distinct, never a node outside the candidate's org), asks
Jev about every proposal in one `join`, and writes both answers back:

    top proposal at P >= accept, and the only one   aiq.promote_soft_node
    proposal at P < reject                          aiq.record_distinct
    anything between                                left for the next pass

Both writes carry tier `decision_model`, the version that answered, and the
probabilities, so "how much of this graph rests on a model's decision" stays a
GROUP BY (graph-identity.md D11).

THE QUESTION AND BOTH THRESHOLDS ARE REQUIRED. A threshold belongs to the
wording of its question (`percolate_core.decide`): one rewording moved 114 of
the accept decisions measured on company names with the ranking unchanged, so
a default threshold would be a number measured for a question nobody asked.
The step that runs this says all three, e.g.

    op: resolve
    claimed_kind: company
    question: Do `record` and `candidate` name the same company -- the same
              issuer, not a similarly named company or a related entity?
    accept: 0.8
    reject: 0.2

TWO PROPOSALS ABOVE accept IS NOT A DECISION. Two registered nodes the model
says the candidate is: the registry has a duplicate or the model cannot tell,
and either way merging into one of them is a guess. Counted as `ambiguous`.

NO TRANSACTION IS HELD ACROSS A MODEL CALL. A page is read in one short
transaction, decided outside any, and each decision written in its own: a
candidate another resolver promoted meanwhile fails alone instead of rolling
back the page, and a slow model holds no locks.
"""

from __future__ import annotations

from collections import OrderedDict
from typing import Any

from ..core import as_service
from ..decide import MODEL, Jev
from ..worker import TerminalError

__all__ = ["resolve"]

TIER = "decision_model"


def _required(spec: dict, key: str, kind: type) -> Any:
    if spec.get(key) is None:
        raise TerminalError(f"resolve needs `{key}`: the question and both thresholds are "
                            "the author's, because a threshold is measured for one wording")
    try:
        return kind(spec[key])
    except (TypeError, ValueError):
        raise TerminalError(f"resolve: `{key}` must be a {kind.__name__}") from None


async def _page(spec: dict, after: str | None) -> "OrderedDict[str, dict]":
    async with as_service() as conn:
        rows = await conn.fetch(
            "select * from aiq.resolution_candidates($1, $2, $3::uuid, $4, $5, $6)",
            spec.get("claimed_kind"), spec.get("entity_type"), after,
            int(spec.get("limit", 50)), int(spec.get("k", 5)), float(spec.get("min_sim", 0.3)))
    page: OrderedDict[str, dict] = OrderedDict()
    for r in rows:
        sid = str(r["soft_id"])
        c = page.setdefault(sid, {"candidate_node_id": str(r["candidate_node_id"]),
                                  "name": r["name"], "attrs": r["attrs"], "proposals": {}})
        if r["node_id"] is not None:
            c["proposals"][str(r["node_id"])] = {"name": r["summary"] or r["node_key"]}
    return page


async def _write(sql: str, *args: Any) -> bool:
    """One decision, one transaction. False when the database refused it.

    Evidence goes in as a dict. The pool's jsonb codec encodes it (core
    identity.py); a string already encoded is encoded again, and the first live
    run on production wrote every ledger row's evidence as a JSON string inside
    an array, where `evidence->'p'` finds nothing.
    """
    try:
        async with as_service() as conn:
            await conn.execute(sql, *args)
        return True
    except Exception as err:  # the next decision does not depend on this one
        print(f"[resolve] not written: {err}", flush=True)
        return False


async def resolve(spec: dict, ctx: dict | None = None, jev: Jev | None = None) -> dict:
    """Decide up to `pages` pages of unresolved candidates. Returns a receipt."""
    question = _required(spec, "question", str)
    accept = _required(spec, "accept", float)
    reject = _required(spec, "reject", float)
    if not 0.0 <= reject < accept <= 1.0:
        raise TerminalError("resolve: need 0 <= reject < accept <= 1")
    with_attrs = bool(spec.get("with_attrs", False))
    receipt = {"candidates": 0, "promoted": 0, "distinct": 0, "undecided": 0,
               "ambiguous": 0, "nothing_to_propose": 0, "not_written": 0, "pages": 0}
    own = jev is None
    jev = jev or Jev(spec.get("model") or MODEL)
    try:
        after = None
        for _ in range(int(spec.get("pages", 20))):
            page = await _page(spec, after)
            if not page:
                break
            receipt["pages"] += 1
            after = next(reversed(page))
            asked = [(sid, c) for sid, c in page.items() if c["proposals"]]
            receipt["candidates"] += len(page)
            receipt["nothing_to_propose"] += len(page) - len(asked)
            probs = await jev.join(
                [{"name": c["name"], **({"attributes": c["attrs"]} if with_attrs and c["attrs"] else {})}
                 for _, c in asked],
                [c["proposals"] for _, c in asked], question)
            decided_by = f"percolate-core:resolve:{jev.model}"
            for (sid, c), p in zip(asked, probs):
                above = sorted((v, k) for k, v in p.items() if v >= accept)
                evidence = {"model": jev.model, "question": question, "accept": accept,
                            "reject": reject, "p": p}
                if len(above) > 1:
                    receipt["ambiguous"] += 1
                    continue
                if above:
                    ok = await _write(
                        "select aiq.promote_soft_node($1::uuid, $2::uuid, $3, $4, $5::jsonb)",
                        sid, above[0][1], decided_by, TIER, evidence)
                    receipt["promoted" if ok else "not_written"] += 1
                    continue
                noes = [k for k, v in p.items() if v < reject]
                for node in noes:
                    ok = await _write(
                        "select aiq.record_distinct($1::uuid, $2::uuid, $3, $4, $5::jsonb)",
                        c["candidate_node_id"], node, decided_by, TIER,
                        {**evidence, "p": p[node]})
                    receipt["distinct" if ok else "not_written"] += 1
                if len(noes) < len(p):
                    receipt["undecided"] += 1
        receipt.update(model=jev.model, requests=jev.requests, input_tokens=jev.input_tokens)
        return receipt
    finally:
        if own:
            await jev.aclose()
