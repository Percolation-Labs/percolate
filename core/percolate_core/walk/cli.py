"""`percolate walk`: the clue walk's commands (muddling-through-walkthrough.md §2).

    percolate walk run --channel beam-1m22 --questions questions.jsonl --question 1M:22:multi_session_reasoning:1 \\
        --verdicts verdicts.json --record walk.json
    percolate walk why walk.json --gold gold.json

`run` walks one question. With `--verdicts` it answers from a verdict file and asks Jev only for clues the file
lacks; `--offline` asks nobody and leaves those unjudged; `--save-verdicts` writes every verdict the walk was given,
so the next run of the same walk is free. `why` explains an incomplete answer from the record alone.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any, Optional

import typer

from . import why as W
from .engine import Settings, walk

app = typer.Typer(help="The clue walk: run it, index the clues it follows, and say why an answer is incomplete",
                  no_args_is_help=True)


def _gold(value: str, qid: Any) -> list[str]:
    """Evidence ids: a comma list, a JSON file holding a list or {question id: list}, or a questions file in JSON
    lines whose rows carry `id` (or `qid`, as BEAM's do) and `gold`, as a sample ships it."""
    path = Path(value)
    if not path.is_file():
        return [x.strip() for x in value.split(",") if x.strip()]
    text = path.read_text()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        data = {str(q.get("id", q.get("qid"))): q.get("gold", []) for q in map(json.loads, text.splitlines()) if q}
    if isinstance(data, dict) and "gold" in data:  # a questions file of one line
        data = {str(data.get("id", data.get("qid"))): data["gold"]}
    if isinstance(data, dict):
        if str(qid) not in {str(k) for k in data}:
            raise typer.BadParameter(f"{value} holds no evidence for question {qid}", param_hint="--gold")
        return next(v for k, v in data.items() if str(k) == str(qid))
    return data


@app.command("why")
def why_command(
    record: Path = typer.Argument(..., exists=True, dir_okay=False, help="A walk record: one JSON object, or one per line"),
    gold: str = typer.Option(None, "--gold", help="The answer key: evidence ids as a comma list, a JSON file "
                             "(a list, or {question id: list}), or a questions file in JSON lines with gold. Adds why "
                             "each unread one was missed."),
    question: str = typer.Option(None, "--question", help="Only the walk for this question id"),
    as_json: bool = typer.Option(False, "--json", help="Print JSON instead of the text blocks"),
) -> None:
    """Why a walk's answer is incomplete, from its record alone: the state at the stop, the leads it left open and
    the near misses; with --gold, for each unread piece of evidence, (a) never offered, (b) rejected with its P,
    or (c) open or queued when the walk stopped."""
    walks = W.load(record)
    if question is not None:
        walks = [r for r in walks if str((r.get("question") or {}).get("id")) == question]
        if not walks:
            raise typer.BadParameter(f"no walk for question {question} in {record}", param_hint="--question")
    for r in walks:
        qid = (r.get("question") or {}).get("id")
        out = W.explain(r, None if gold is None else _gold(gold, qid))
        typer.echo(json.dumps(out) if as_json else W.render(out))


def _questions(path: Optional[Path], store: Any) -> dict[str, dict]:
    """{id: {id, text, gold?, search?}}. A file may say `qid` and `question`, as BEAM's own files do."""
    if not path:
        return getattr(store, "questions", {})
    out = {}
    for q in map(json.loads, path.read_text().splitlines()):
        if q:
            q = {**q, "id": str(q.get("id", q.get("qid"))), "text": q.get("text", q.get("question"))}
            out[q["id"]] = q
    return out


async def _embed(content_url: str, text: str) -> list[float]:
    import httpx

    token = os.environ.get("P8_TOKEN") or os.environ.get("TOKEN")
    if not token:
        raise typer.BadParameter("searching Percolate needs a signed-in caller: set TOKEN (percolate auth token)")
    async with httpx.AsyncClient(timeout=60) as http:
        r = await http.post(f"{content_url.rstrip('/')}/embed", json={"texts": [text]},
                            headers={"Authorization": f"Bearer {token}"})
        r.raise_for_status()
        return r.json()["vectors"][0]


def _table(rec: dict[str, Any], gold: set, order: list) -> list[str]:
    """One row a wave. With an answer key, the evidence the walk has read beside the evidence plain search holds in
    as many of its own results: the same budget of reads, spent two ways."""
    head = "wave  reads  accepted  fresh  open leads" + ("  evidence: walk  search alone" if gold else "")
    lines, read = [head], set()
    for w in rec["waves"]:
        read |= set(w["reads"])
        fresh = "  -  " if w["fresh"] is None else f"{w['fresh']:.2f}"
        row = f"{w['wave']:>4}  {len(read):>5}  {w['accepted']:>8}  {fresh:>5}  {len(w['open']):>10}"
        if gold:
            alone = len(set(order[:len(read)]) & gold)
            row += f"  {len(read & gold):>9} of {len(gold):<4} {alone:>5} of {len(gold)}"
        lines.append(row)
    if gold and len(order) < len(read):
        lines.append(f"(search returned {len(order)} results, so past that it holds no more)")
    return lines


@app.command()
def run(
    question: str = typer.Option(..., "--question", "-q", help="The question's id, in --questions or the fixture."),
    questions: Optional[Path] = typer.Option(None, help="JSON lines of {id, text, gold?}."),
    channel: Optional[str] = typer.Option(None, help="Walk this channel's chunks in Percolate."),
    fixture: Optional[Path] = typer.Option(None, help="Walk a fixture directory instead (docs.jsonl, questions.jsonl)."),
    dsn: Optional[str] = typer.Option(None, help="Default: P8_DSN."),
    content_url: Optional[str] = typer.Option(
        None, help="The Content Server, which embeds the question with the corpus's model. Default: P8_CONTENT_URL, "
                   "then localhost at P8_CONTENT_PORT."),
    verdicts: Optional[Path] = typer.Option(None, help="Answer clues from this verdict file first."),
    offline: bool = typer.Option(False, help="Ask no model: a clue the verdict file lacks stays unjudged."),
    save_verdicts: Optional[Path] = typer.Option(None, help="Write every verdict this walk was given here."),
    record: Optional[Path] = typer.Option(None, help="Write the walk's record here."),
    policy: str = typer.Option("explore", help="best: the 3 best accepted clues a step; explore: 2 best and 1 drawn by P."),
    waves: int = typer.Option(10, help="Waves of 50 reads."),
    expand_all: bool = typer.Option(True, "--expand-all/--seeds-only",
                                    help="Every read raises clues, or only search's first 10 and what clues reach."),
) -> None:
    """Walk one question and print each wave: reads, accepted clues, freshness and the leads still open."""
    from .deciders import Recorder, Replay, jev

    if bool(channel) == bool(fixture):
        raise typer.BadParameter("walk a --channel in Percolate or a --fixture, one of the two")

    async def go() -> int:
        conn = None
        if fixture:
            from .store import MemoryStore
            store: Any = MemoryStore(fixture)
        else:
            from ..core.cli import _connect  # the CLI's one bare connection: a walk reads, and binds no jsonb
            from .store import PgStore
            conn = await _connect(dsn or os.environ.get("P8_DSN"))
            store = await PgStore.load(conn, channel)
        qs = _questions(questions, store)
        if question not in qs:
            raise typer.BadParameter(f"no question {question!r} in {questions or fixture}")
        q = qs[question]
        if conn is not None and not q.get("search"):
            url = content_url or os.environ.get("P8_CONTENT_URL") or \
                f"http://localhost:{os.environ.get('P8_CONTENT_PORT', '8081')}"
            await store.order(conn, q, await _embed(url, q["text"]))
        live = None if offline else jev()
        decide: Any = Replay(verdicts, fallback=live) if verdicts else live
        if decide is None:
            typer.secho("--offline needs --verdicts: with neither, nothing can judge a clue", fg="red", err=True)
            return 2
        rec_dec = Recorder(decide) if save_verdicts else None
        try:
            rec = await walk(store, q, rec_dec or decide, Settings(waves=waves, policy=policy, expand_all=expand_all))
        finally:
            if conn is not None:
                await conn.close()
        for line in _table(rec, set(q.get("gold", ())), list(store.search(q))):
            typer.echo(line)
        typer.echo(f"stop: {rec['stop']['detail']}; {rec['reads']} reads; {len(rec['open'])} accepted leads never "
                   f"travelled; {rec['unjudged']} clues unjudged")
        if isinstance(decide, Replay):
            typer.echo(f"verdicts: {sum(c['P'] is not None for c in rec['clues']) - decide.asked} from "
                       f"{verdicts.name}, {decide.asked} asked of Jev, {decide.missing} missing")
        if record:
            record.write_text(json.dumps(rec, indent=1, default=str) + "\n")
            typer.echo(f"record: {record}")
        if rec_dec:
            rec_dec.save(save_verdicts)
            typer.echo(f"verdicts saved: {save_verdicts}")
        return 0

    raise typer.Exit(asyncio.run(go()))


@app.command("index")
def index(
    source: str = typer.Option(..., "--source", help="The channel whose documents to index."),
    dsn: Optional[str] = typer.Option(None, help="Owner-level DSN. Default: P8_ADMIN_DSN, then P8_DSN."),
    nearest: Optional[int] = typer.Option(None, help="How many nearest documents to link from each. "
                                          "Default: aiq.parameters' index.nearest."),
) -> None:
    """Write walk_term, walk_next and walk_nearest edges for one source's documents (REM-1201).

    Every edge is derived from the stored text and vectors, never from a model's verdict, and a second run changes
    nothing unless the documents did.
    """
    from ..core.cli import _admin_dsn, _connect
    from .index import index as build

    async def _run() -> dict:
        conn = await _connect(_admin_dsn(dsn))
        try:
            return await build(conn, source, nearest)
        finally:
            await conn.close()

    try:
        report = asyncio.run(_run())
    except RuntimeError as err:
        typer.secho(str(err), fg=typer.colors.RED, err=True)
        raise typer.Exit(1)
    typer.echo(json.dumps(report, indent=2))
