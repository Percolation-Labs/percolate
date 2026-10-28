"""Why a walk's answer is incomplete, from the walk's record alone (muddling-through-walkthrough.md §2.5).

Two blocks.

AUDIT needs no answer key; it is what a caller gets after any walk. The state at the stop, judged on the last wave
that read:

    unknown    that wave expanded no read (fresh is null), so its temperature says nothing
    ran dry    the walk found nothing left to read before its last wave
    warm       a share of at least COLD of that wave's expanded reads raised a newly accepted lead
    cold       under COLD; with no accepted lead left open it is the certificate, otherwise the open leads are listed

A clue nobody judged (an offline replay) could not have been accepted: with no clue judged the state is unknown, and
while unjudged clues still point at unread documents there is no certificate.

then the accepted leads still open, with P and how many unread documents each leads to, and the rejected leads just
under the gate (P NEAR_MISS to the gate) that still point at unread documents.

WHY needs the answer key (`gold`). For each evidence document the walk did not read, the first of these that holds:

    queued          (c)  a travelled lead reached it; the walk stopped before reading it
    open            (c)  an accepted lead pointing at it was still open at the stop, with its rank among the open
    rejected        (b)  the best judged lead pointing at it was under the gate, with its P
    unjudged        (?)  a lead pointed at it but the decider gave no P (an --offline replay, or a refusal)
    never offered   (a)  no lead raised in the walk pointed at it

Anything the record does not hold is printed as missing, never filled in: the record is what the walk saw, and the
store may have changed since (engine.py). The finer reasons the study gave for (a) -- a term above the cap, a
document linked only from a read that raised no leads -- need the graph, which the record does not hold, so they are
not guessed at here.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable, Mapping

# Neither is measured. A last wave under COLD's share of fresh reads reads cold (REM-1194's coverage study binned cold
# at 0.2, not this). NEAR_MISS is a reporting band 0.15 under the gate, the band REM-1207's walkthrough travelled.
COLD = 0.05
NEAR_MISS = 0.35
LETTER = {"queued": "c", "open": "c", "rejected": "b", "unjudged": "?", "never offered": "a"}
MISSING = "missing"


def _id(x: Any) -> str:
    # Documents are compared as strings: the record keeps the store's ids as JSON, gold arrives from a command line.
    return str(x)


def _order(x: str) -> tuple:
    return (0, int(x), "") if x.lstrip("-").isdigit() else (1, 0, x)


def _missing(record: Mapping[str, Any], *fields: str) -> list[str]:
    return [f for f in fields if f not in record]


def audit(record: Mapping[str, Any]) -> dict[str, Any]:
    """The gold-free block: what the record says about where the walk stopped and what it left."""
    gone = _missing(record, "waves", "clues", "open", "settings", "stop")
    waves = record.get("waves") or []
    read = {_id(d) for w in waves for d in w.get("reads", ())}
    gate = (record.get("settings") or {}).get("gate")
    # judge the last wave that read: an empty wave after it has no temperature of its own
    last = next((w for w in reversed(waves) if w.get("reads")), waves[-1] if waves else {})
    stop = record.get("stop") or {}
    clues = record.get("clues") or []
    judged = sum(c.get("P") is not None for c in clues)
    # unjudged clues still pointing at unread documents: nobody could accept them, so they bar the certificate
    blind = sum(c.get("P") is None and any(_id(t) not in read for t in c.get("targets", ())) for c in clues)

    if not waves or "fresh" not in last:
        state = f"{MISSING}: the record holds no per-wave temperature"
    elif clues and not judged:
        state = "unknown: no clue was judged (an offline run), so no lead could be accepted"
    elif last["fresh"] is None:
        state = "unknown: the last wave expanded no read, so its temperature says nothing"
    else:
        state = None
    opn = sorted(((k, v["P"], sum(_id(t) not in read for t in v.get("targets", ())))
                  for k, v in (record.get("open") or {}).items()), key=lambda r: (-r[1], r[0]))
    opn = [r for r in opn if r[2]]
    if state is None:
        ending = ("accepted leads open" if opn else
                  f"no accepted lead open, but {blind} unjudged leads still point at unread documents (no certificate)"
                  if blind else "no accepted lead open (certificate)")
        if stop.get("reason") == "dry":
            state = f"ran dry after wave {last.get('wave', len(waves))}; {ending}"
        elif last["fresh"] >= COLD:
            state = "warm: still finding new accepted leads"
        else:
            state = f"cold, {ending}"

    near: dict[str, tuple[float, int]] = {}
    if gate is not None:
        for c in record.get("clues") or ():
            p = c.get("P")
            if p is not None and NEAR_MISS <= p < gate:
                n = sum(_id(t) not in read for t in c.get("targets", ()))
                if n and p > near.get(c["key"], (-1, 0))[0]:
                    near[c["key"]] = (p, n)
    return {
        "question": (record.get("question") or {}).get("text", MISSING),
        "reads": len(read) if waves else MISSING,
        "waves": [len(w.get("reads", ())) for w in waves] or MISSING,
        "stop": stop or MISSING,
        "gate": MISSING if gate is None else gate,
        "state": state,
        "last wave fresh": last.get("fresh", MISSING) if waves else MISSING,
        "judged": sum(c.get("P") is not None for c in clues) if "clues" in record else MISSING,
        "accepted": sum(c.get("decision") == "accepted" for c in clues) if "clues" in record else MISSING,
        "unjudged": record.get("unjudged", MISSING),
        "queued": len(record["pending"]) if "pending" in record else MISSING,
        "open": [list(r) for r in opn] if "open" in record else MISSING,
        "near misses": sorted(([k, p, n] for k, (p, n) in near.items()), key=lambda r: (-r[1], r[0]))
        if gate is not None and "clues" in record else MISSING,
        "missing": gone,
    }


def why(record: Mapping[str, Any], gold: Iterable[Any]) -> dict[str, list[Any]]:
    """For each gold document the walk did not read, its reason and the lead behind it."""
    waves = record.get("waves") or []
    read = {_id(d) for w in waves for d in w.get("reads", ())}
    pending = {_id(d) for d in record.get("pending", ())}
    gate = (record.get("settings") or {}).get("gate", 0.5)
    opn = {k: v for k, v in (record.get("open") or {}).items()
           if any(_id(t) not in read for t in v.get("targets", ()))}
    out: dict[str, list[Any]] = {}
    for g in sorted({_id(x) for x in gold} - read, key=_order):
        pointing = [c for c in record.get("clues") or () if g in {_id(t) for t in c.get("targets", ())}]
        judged = [c for c in pointing if c.get("P") is not None]
        held = [k for k, v in opn.items() if g in {_id(t) for t in v.get("targets", ())}]
        if g in pending:
            out[g] = ["queued", "a travelled lead reached it; the walk stopped before reading it"]
        elif held:
            k = max(held, key=lambda k: (opn[k]["P"], k))
            p = opn[k]["P"]
            out[g] = ["open", k, p, f"rank {1 + sum(v['P'] > p for v in opn.values())} of {len(opn)} open by P"]
        elif judged and max(c["P"] for c in judged) < gate:
            c = max(judged, key=lambda c: (c["P"], c["key"]))
            out[g] = ["rejected", c["key"], c["P"]]
        elif judged:
            # accepted, never travelled and not open: the engine should not leave one; say so rather than hide it
            c = max(judged, key=lambda c: (c["P"], c["key"]))
            out[g] = ["unjudged", c["key"], c["P"], "accepted but neither travelled nor open: the record is inconsistent"]
        elif pointing:
            out[g] = ["unjudged", pointing[0]["key"], "no P recorded"]
        else:
            out[g] = ["never offered", "no lead raised in the walk pointed at it"]
    return out


def explain(record: Mapping[str, Any], gold: Iterable[Any] | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"id": (record.get("question") or {}).get("id", MISSING), "audit": audit(record)}
    if gold is not None:
        gold = list(gold)
        out["evidence"] = len({_id(g) for g in gold})
        out["why"] = why(record, gold)
    return out


def render(r: Mapping[str, Any]) -> str:
    a = r["audit"]
    lines = [f"## {r['id']}", f"> {a['question']}", "", "audit (no answer key)", ""]
    lines.append(f"- {a['reads']} reads, waves {a['waves']}; {a['judged']} leads judged, {a['accepted']} accepted, "
                 f"{a['unjudged']} unjudged; {a['queued']} queued and not yet read")
    stop = a["stop"]
    lines.append(f"- stopped: {stop.get('reason', MISSING)}" + (f", {stop['detail']}" if stop.get("detail") else "")
                 if isinstance(stop, dict) else f"- stopped: {stop}")
    lines.append(f"- state at the stop: {a['state']} (last wave fresh: {a['last wave fresh']})")
    if isinstance(a["open"], list):
        lines.append(f"- {len(a['open'])} accepted leads still open")
        lines += [f"    - {k}  P {p}, leaves {n} unread" for k, p, n in a["open"][:5]]
    else:
        lines.append(f"- accepted leads still open: {a['open']}")
    if isinstance(a["near misses"], list):
        lines.append(f"- {len(a['near misses'])} rejected leads at P {NEAR_MISS} to {a['gate']} still point at unread "
                     "documents")
        lines += [f"    - {k}  P {p}, {n} unread" for k, p, n in a["near misses"][:3]]
    else:
        lines.append(f"- near misses: {a['near misses']}")
    if a["missing"]:
        lines.append(f"- {MISSING} from the record: {', '.join(a['missing'])}")
    if "why" in r:
        lines += ["", f"why (answer key): {r['evidence'] - len(r['why'])} of {r['evidence']} evidence documents read", ""]
        for g, v in r["why"].items():
            lines.append(f"- {g} ({LETTER[v[0]]}) {v[0]}: {', '.join(str(x) for x in v[1:])}")
    return "\n".join(lines) + "\n"


def load(path: str | Path) -> list[dict[str, Any]]:
    """A record file: one walk as a JSON object, or one walk per line."""
    text = Path(path).read_text()
    try:
        one = json.loads(text)
        return one if isinstance(one, list) else [one]
    except json.JSONDecodeError:
        return [json.loads(line) for line in text.splitlines() if line.strip()]
