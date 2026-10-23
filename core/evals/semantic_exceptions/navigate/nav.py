"""A repository over the Dracula store, with semantic exceptions on its search.

    nav.py task "what you are trying to find out"     start a task (resets the walk)
    nav.py search "question" [filters] [--limit 8] [--force]
    nav.py list [filters] [--with TEXT] [--without TEXT] [--by-entry] [--limit 30]
    nav.py grep "exact phrase|another phrase" [filters] [--by-entry] [--limit 30]
    nav.py read ID
    nav.py around ID

    filters: --source NAME   narrator or author (substring, any case)
             --document TEXT the document it belongs to (substring)
             --after YYYY-MM-DD --before YYYY-MM-DD   by the entry's date (inclusive)

The store holds Bram Stoker's Dracula as 644 passages of about 200 words,
each from a dated journal entry, letter, telegram, cutting or log, with its
narrator, document and date. `search` ranks passages by meaning and words
together. `list` and `grep` are exact: every passage that matches, and a count.
Matching starts at a word ("Art" finds Arthur, not heart) and ignores case,
line breaks and curly quotes; `|` in a grep phrase means or. `--by-entry` applies --with/--without/grep to whole entries (a letter or a
day's journal) rather than to single passages, and lists the entries.

Exceptions: every `search` is inspected by percolate_core.semantic_exceptions
at the measured thresholds -- the question before it runs, the result, the top
passages, and the searches so far in this task. A question that raises an
error is refused before searching; `--force` searches anyway.
NAV_EXCEPTIONS=off turns all of it off (the control arm). NAV_SESSION names the
task log (default "default").
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import re
import sys
from collections import Counter
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]))
STORE, SESSIONS = HERE / "store", HERE / "sessions"
STORE_DESCRIPTION = ("Bram Stoker's Dracula (1897) as dated documents: journal entries, letters, "
                     "telegrams, newspaper cuttings, a ship's log and a phonograph diary.")
EXCEPTIONS = os.environ.get("NAV_EXCEPTIONS", "on") != "off"
SESSION = SESSIONS / f"{os.environ.get('NAV_SESSION', 'default')}.json"
# Absolute score thresholds stay off: nothing has measured them for bge-small on
# this store, and a guessed cosine cut-off is the noise they exist to avoid.
LIMITS = dict(low_score=None, flat_spread=None, min_gap=None)
# This repository's own next step for each kind, in its own commands. The kind's
# prompt says what to do in general; only the repository knows how.
ACTIONS = {
    "DECOMPOSITION_REQUIRED": "run one `search` per part.",
    "TWO_QUESTIONS": "run one `search` per question.",
    "NEGATION": "`list --without \"TERM|OTHER NAME\" --by-entry` (with --source/--after/"
                "--before) gives the exact complement by whole entry; name every way the "
                "records refer to the thing, not just one word.",
    "COUNT": "`list` and `grep` print an exact count of passages and entries.",
    "SUPERLATIVE": "`list` and `grep` print matches in date order; for an idea with many "
                   "phrasings, `search` again with `--before` the earliest date found until "
                   "nothing earlier comes back (or `--after` the latest).",
    "EXHAUSTIVE": "`grep \"a|b|c\"` every name you find and `list` with filters; read "
                  "`around` any passage that holds part of the list.",
    "COMPARISON": "`search` each side with its own --source.",
    "CONJUNCTION": "`search` or `grep` each condition, then keep what both return.",
    "CAUSAL_WHY": "find the event, then `search --before` its date for what led to it.",
    "EXACT_MATCH": "`grep \"phrase\"` matches exactly.",
    "KNOWN_VS_HAPPENED": "a passage's date is when its entry was written; read it for when the "
                         "event happened.",
    "RELATIVE_TIME": "every entry is dated in 1893; anchor to the date of the entry in question.",
    "ARITHMETIC": "every passage carries its date; fetch the values and compute.",
    "MISSING_REFERENT": "name the people or thing meant and search again.",
    "POINTER": "`around ID` reads the neighbouring passages; `grep` the name of what it "
               "points to.",
    "TRUNCATED": "`around ID` reads the rest.",
    "CONTINUES": "`around ID` reads the parts before and after.",
    "HEARSAY": "`search` again with --source set to the person it came from.",
    "SPECULATIVE": "look for a later passage that confirms or drops it (`search --after`).",
    "CONFLICT": "`read` both and compare their dates and narrators.",
    "SINGLE_SOURCE": "`search` again with another --source.",
    "TIME_SKEW": "`search` again with --after or --before outside that period.",
    "LOOP": "change the words or the filters (--source, --after, --before), or answer.",
    "OFF_QUESTION": "rephrase in the words the narrators would use.",
}

P = [json.loads(l) for l in (STORE / "passages.jsonl").read_text().splitlines()]
BY_ID = {p["id"]: i for i, p in enumerate(P)}
WORD = re.compile(r"[a-z0-9']+")


def toks(s: str) -> list[str]:
    return WORD.findall(s.lower())


def filtered(a) -> list[int]:
    out = []
    for i, p in enumerate(P):
        if a.source and a.source.lower() not in (p["source"] or "").lower():
            continue
        if a.document and a.document.lower() not in (p["document"] or "").lower():
            continue
        if a.after and (p["time"] is None or p["time"] < a.after):
            continue
        if a.before and (p["time"] is None or p["time"] > a.before):
            continue
        out.append(i)
    return out


def bm25(query: str, ids: list[int]) -> dict[int, float]:
    q = toks(query)
    docs = {i: toks(P[i]["content"]) for i in ids}
    n = len(docs) or 1
    avg = sum(len(d) for d in docs.values()) / n
    df = Counter(t for d in docs.values() for t in set(d))
    out = {}
    for i, d in docs.items():
        tf = Counter(d)
        s = sum(math.log(1 + (n - df[t] + .5) / (df[t] + .5)) * tf[t] * 2.2
                / (tf[t] + 1.2 * (.25 + .75 * len(d) / avg)) for t in q if t in tf)
        if s > 0:
            out[i] = s
    return out


def embed(text: str) -> np.ndarray:
    from fastembed import TextEmbedding
    v = np.array(next(iter(TextEmbedding("BAAI/bge-small-en-v1.5").embed([text]))), dtype=np.float32)
    return v / np.linalg.norm(v)


def hits_for(question: str, ids: list[int], limit: int) -> list[dict]:
    vecs = np.load(STORE / "vectors.npy")
    q = embed(question) if ids else None
    cos = {i: float(vecs[i] @ q) for i in ids}
    lex = bm25(question, ids)
    sem_rank = {i: r for r, i in enumerate(sorted(cos, key=cos.get, reverse=True), 1)}
    lex_rank = {i: r for r, i in enumerate(sorted(lex, key=lex.get, reverse=True), 1)}
    fused = {i: 1 / (60 + sem_rank[i]) + (1 / (60 + lex_rank[i]) if i in lex_rank else 0)
             for i in ids}
    top = sorted(fused, key=fused.get, reverse=True)[:limit]
    return [{**P[i], "score": round(cos[i], 4)} for i in top]


def show(p: dict, words: int | None = 60) -> str:
    text = " ".join(p["content"].split())
    if words:
        w = text.split()
        text = " ".join(w[:words]) + (" ..." if len(w) > words else "")
    when = p["time"] or "undated"
    return (f"[{p['id']}] {when} | {p['source']} | {p['document']} | part {p['part']}/{p['parts']}"
            + (f" | score {p['score']}" if "score" in p else "") + f"\n    {text}")


def session() -> dict:
    try:
        return json.loads(SESSION.read_text())
    except (OSError, ValueError):
        return {"task": None, "rounds": []}


def save(s: dict) -> None:
    SESSIONS.mkdir(exist_ok=True)
    SESSION.write_text(json.dumps(s))


def jev_key() -> str:
    if os.environ.get("JEV_API_KEY"):
        return os.environ["JEV_API_KEY"]
    env = Path(os.environ.get("JEV_ENV_FILE", ".env"))
    for line in (env.read_text().splitlines() if env.exists() else []):
        if line.startswith("JEV_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("no JEV_API_KEY")


async def do_search(a) -> None:
    from percolate_core.decide import Jev
    from percolate_core.semantic_exceptions import Limits, Report, SemanticExceptions
    ids = filtered(a)
    s = session()
    if not EXCEPTIONS:
        hits = hits_for(a.question, ids, a.limit)
        print(f"{len(hits)} passages:")
        print("\n".join(show(h) for h in hits))
        return
    async with Jev(api_key=jev_key()) as jev:
        sx = SemanticExceptions(jev, store=STORE_DESCRIPTION, limits=Limits(**LIMITS),
                                values_top=4, actions=ACTIONS)
        report = await sx.before(a.question)
        if report.errors and not a.force:
            print("REFUSED: the question was not searched.")
            print(report.to_prompt())
            print("(Search anyway with --force.)")
            SESSIONS.mkdir(exist_ok=True)
            with open(SESSIONS / f"{SESSION.stem}.log.jsonl", "a") as f:
                f.write(json.dumps({"question": a.question, "refused": [r.code for r in report.errors]}) + "\n")
            return
        # --force acknowledges the errors: say so once rather than repeat them.
        forced = [r.code for r in report.errors]
        report.raised = [r for r in report.raised if r.kind.severity != "error"]
        hits = hits_for(a.question, ids, a.limit)
        times = sorted(p["time"] for p in P if p["time"])
        from datetime import date
        d = lambda t: date.fromisoformat(t).toordinal()  # noqa: E731
        # The module's fields only. A diary is a series of entries, not versions
        # of one document, so `document` is not `version_of`; filters run before
        # ranking over every passage, so nothing is ever starved by a filter.
        # A filter the user chose is not something the store detected: no
        # SINGLE_SOURCE under --source, and TIME_SKEW is measured against the
        # window asked for, not the whole store. Only the top hit can CONTINUE.
        hit_t = [{"id": h["id"], "score": h["score"], "content": h["content"],
                  "time": d(h["time"]) if h["time"] else None,
                  "continues": h["parts"] > 1 and n == 0,
                  **({} if a.source else {"source": h["source"]})}
                 for n, h in enumerate(hits)]
        window = (d(a.after or times[0]), d(a.before or times[-1]))
        report += sx.after(hit_t, limit=a.limit, time_range=window)
        if hits:
            report += await sx.values(a.question, hits)
        # Each search asks its own question and settles it; the walk is the
        # task's searches, so a repeat that finds nothing new is a LOOP.
        s["rounds"].append({"found": [h["id"] for h in hits], "opened": [a.question],
                            "closed": [a.question]})
        report += sx.walk(s["rounds"])
        seen = set(s.get("seen", []))
        report = report.novel(seen)
        s["seen"] = sorted(seen)
        save(s)
        with open(SESSIONS / f"{SESSION.stem}.log.jsonl", "a") as f:
            f.write(json.dumps({"question": a.question, "forced": forced,
                                "raised": [[r.code, r.p] for r in report.raised]}) + "\n")
    print(f"{len(hits)} passages:")
    print("\n".join(show(h) for h in hits))
    if forced:
        print(f"\n(Searched past {', '.join(forced)} at your request.)")
    text = report.to_prompt(show=6)
    if text:
        print()
        print(text)


def norm(s: str) -> str:
    s = s.replace("\u2019", "'").replace("\u2018", "'").replace("\u201c", '"').replace("\u201d", '"')
    return " ".join(s.lower().split())


def has(text: str, needle: str) -> bool:
    """At the start of a word: "Art" finds Arthur, not heart (round one and two)."""
    return any(re.search(r"(?<![a-z0-9])" + re.escape(norm(n)), text)
               for n in needle.split("|") if n.strip())


async def do_task(text: str) -> None:
    """The question's shape belongs to the task, not to one search call.

    Round two of the navigation test: users who went straight to `grep` and
    `list` never met a question-stage exception, because only `search` raised
    them. Here the task's own question is judged once, at the start, and the
    result is advice on how to go about it -- never a refusal."""
    from percolate_core.decide import Jev
    from percolate_core.semantic_exceptions import SemanticExceptions
    async with Jev(api_key=jev_key()) as jev:
        sx = SemanticExceptions(jev, store=STORE_DESCRIPTION, actions=ACTIONS)
        report = await sx.before(text)
    s = session()
    seen: set = set()
    report.novel(seen)
    s["seen"] = sorted(seen)
    save(s)
    with open(SESSIONS / f"{SESSION.stem}.log.jsonl", "a") as f:
        f.write(json.dumps({"task": text, "raised": [[r.code, r.p] for r in report.raised]}) + "\n")
    if report.raised:
        print()
        print(report.to_prompt(show=6).replace(
            "Act on these before answering:", "Plan for these before you start:"))


def do_list(a, phrase: str | None = None) -> None:
    ids = filtered(a)
    text = {i: norm(P[i]["content"]) for i in ids}
    if a.by_entry:
        # whole entries: an entry has a term if any of its passages does
        whole: dict[str, str] = {}
        for i in ids:
            whole[P[i]["entry"]] = whole.get(P[i]["entry"], "") + " " + text[i]
        text = {i: whole[P[i]["entry"]] for i in ids}
    if a.with_ or phrase:
        ids = [i for i in ids if has(text[i], phrase or a.with_)]
    if a.without:
        ids = [i for i in ids if not has(text[i], a.without)]
    entries = {P[i]["entry"] for i in ids}
    print(f"{len(ids)} passages match ({len(entries)} entries).")
    if a.by_entry:
        firsts = {}
        for i in ids:
            firsts.setdefault(P[i]["entry"], i)
        for e, i in list(firsts.items())[: a.limit]:
            p = P[i]
            print(f"[{e}] {p['time']} | {p['source']} | {p['document']} | {p['parts']} passage(s)")
        if len(firsts) > a.limit:
            print(f"... {len(firsts) - a.limit} more entries not shown (raise --limit).")
        return
    for i in ids[: a.limit]:
        p = P[i]
        if phrase:
            t = " ".join(p["content"].split())
            k = max((norm(t).find(norm(n)) for n in phrase.split("|")), default=0)
            print(f"[{p['id']}] {p['time']} | {p['source']} | ...{t[max(0, k - 80): k + 120]}...")
        else:
            first = " ".join(p["content"].split()[:14])
            print(f"[{p['id']}] {p['time']} | {p['source']} | {p['document']} | {first} ...")
    if len(ids) > a.limit:
        print(f"... {len(ids) - a.limit} more not shown (raise --limit).")


def main() -> None:
    doc = __doc__ if EXCEPTIONS else __doc__.split("Exceptions:")[0]
    ap = argparse.ArgumentParser(description=doc, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("task")
    t.add_argument("text")
    for name in ("search", "list", "grep"):
        p = sub.add_parser(name)
        if name == "search":
            p.add_argument("question")
            p.add_argument("--force", action="store_true")
        if name == "grep":
            p.add_argument("phrase")
        p.add_argument("--source")
        p.add_argument("--document")
        p.add_argument("--after")
        p.add_argument("--before")
        p.add_argument("--limit", type=int, default=8 if name == "search" else 30)
        if name == "list":
            p.add_argument("--with", dest="with_")
            p.add_argument("--without")
        if name in ("list", "grep"):
            p.add_argument("--by-entry", action="store_true")
    for name in ("read", "around"):
        sub.add_parser(name).add_argument("id")
    a = ap.parse_args()
    if a.cmd == "task":
        save({"task": a.text, "rounds": []})
        print("task started; the walk log is empty.")
        if EXCEPTIONS:
            asyncio.run(do_task(a.text))
    elif a.cmd == "search":
        asyncio.run(do_search(a))
    elif a.cmd == "list":
        do_list(a)
    elif a.cmd == "grep":
        a.with_ = a.without = None
        do_list(a, phrase=a.phrase)
    elif a.id not in BY_ID:
        entry = [p["id"] for p in P if p["entry"] == a.id.split(".")[0]]
        raise SystemExit(f"no passage {a.id}." + (f" Entry {a.id.split('.')[0]} has: {', '.join(entry)}."
                                                  if entry else " Ids look like e0106.1."))
    elif a.cmd == "read":
        print(show(P[BY_ID[a.id]], words=None))
    elif a.cmd == "around":
        i = BY_ID[a.id]
        for j in (i - 1, i + 1):
            if 0 <= j < len(P):
                print(show(P[j], words=None))
                print()


if __name__ == "__main__":
    main()
