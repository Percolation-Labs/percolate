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
