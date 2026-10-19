"""`percolate ingest` — run the ingest worker, or try a policy on a local file."""

from __future__ import annotations

import json
import pathlib

import typer

app = typer.Typer(help="Ingestion: parse, chunk and embed uploaded files",
                  no_args_is_help=True)


@app.command()
def serve(queue: str = typer.Option("ingest", "--queue", "-q"),
          worker_id: str = typer.Option(None, "--id")) -> None:
    """Claim ingest steps and run them. The same loop as `percolate worker`."""
    from ..worker import run
    from . import handler  # noqa: F401  -- registers @handler("work")

    run(queue=queue, worker_id=worker_id)


@app.command("embed-selftest")
def embed_selftest(
        model_id: str = typer.Option("BAAI/bge-small-en-v1.5", "--model-id"),
        count: int = typer.Option(64, "--count", help="how many chunks to time"),
        chars: int = typer.Option(1800, "--chars", help="characters per chunk"),
        batch: int = typer.Option(0, "--batch", help="0 uses the local default")) -> None:
    """Load the in-process embedding model and time it, with no database.

    Two questions, answered where the worker runs rather than on a laptop: does
    the model load without reaching the network (it must, because a pod has no
    egress to Hugging Face), and how fast is this machine? The second is why it
    takes a count and a size: the answer differs by an order of magnitude
    between a development Mac and a shared ARM core, and the card that asked
    for this model (REM-628) has numbers only for the first.
    """
    import time

    from .local_embed import DEFAULT_LOCAL_BATCH, assert_offline, embed_local

    t0 = time.perf_counter()
    assert_offline(model_id)
    load_s = time.perf_counter() - t0
    texts = [("word " * (chars // 5))[:chars] for _ in range(count)]
    size = batch or DEFAULT_LOCAL_BATCH
    t0 = time.perf_counter()
    vectors = embed_local(model_id, texts, size)
    took = time.perf_counter() - t0
    one = time.perf_counter()
    embed_local(model_id, ["what does the evidence say about claim scope"], size)
    query_ms = (time.perf_counter() - one) * 1000
    print(json.dumps({"model_id": model_id, "dim": len(vectors[0]),
                      "loaded_offline_s": round(load_s, 2), "chunks": count,
                      "chars_each": chars, "batch": size, "seconds": round(took, 2),
                      "chunks_per_s": round(count / took, 1),
                      "chars_per_s": round(count * chars / took),
                      "query_ms": round(query_ms, 1)}, indent=2))


@app.command()
def file(path: pathlib.Path,
         policy_json: str = typer.Option("{}", "--policy",
                                         help="policy override, as JSON"),
         show: int = typer.Option(2, "--show", help="how many chunks to print")) -> None:
    """Parse and chunk a local file, printing what the database would be sent.

    No database, no object storage, no model. It exists because "why did this
    document chunk like that" is a question about a parser and a policy, and
    answering it should not require an upload, a worker and a run.
    """
    import mimetypes

    from . import chunk as chunker
    from . import parse, tabular
    from .policy import resolve

    data = path.read_bytes()
    ctype = mimetypes.guess_type(path.name)[0]
    family, pol = resolve(ctype, path.name, json.loads(policy_json))
    typer.echo(f"{path.name}: family={family} mode={pol.mode} parser={pol.parser} "
               f"target_tokens={pol.chunking.target_tokens}")

    if pol.mode == "tabular":
        parquet, columns, rows = tabular.to_parquet(data, pol, path.name)
        typer.echo(f"  parquet: {len(parquet)} bytes, {rows} rows, "
                   f"{len(columns)} columns")
        for c in columns:
            typer.echo(f"    {c['name']}: {c['type']}")
        return
    if pol.mode != "text":
        typer.echo(f"  mode {pol.mode}: {len(data)} bytes stored, nothing parsed")
        return

    parsed = parse.to_markdown(data, pol, path.name)
    chunks = chunker.chunk_markdown(parsed.markdown, pol.chunking)
    typer.echo(f"  {parsed.parser}: {len(parsed.markdown)} characters "
               f"-> {len(chunks)} chunks {parsed.detail or ''}")
    for c in chunks[:show]:
        head = c["content"][:200].replace("\n", " ")
        typer.echo(f"    [{c['start_offset']}:{c['end_offset']}] "
                   f"{c['token_count']} tok  {head}…")
