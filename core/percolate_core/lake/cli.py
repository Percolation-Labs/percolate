"""`percolate lake` -- run the lake worker, or ask what this one can reach."""

from __future__ import annotations

import json

import typer

app = typer.Typer(help="The lake: refine staged data in DuckDB before it reaches Postgres",
                  no_args_is_help=True)


@app.command()
def serve(queue: str = typer.Option("lake", "--queue", "-q"),
          worker_id: str = typer.Option(None, "--id")) -> None:
    """Claim refine steps and run them. The same loop as `percolate worker`."""
    from ..worker import run
    from . import handler  # noqa: F401  -- registers @handler("work")

    run(queue=queue, worker_id=worker_id)


@app.command()
def doctor(install: bool = typer.Option(
        False, "--install",
        help="download any missing DuckDB extension (what the image build runs)")) -> None:
    """What this process can do: extensions, object storage, the catalog.

    Each line is checked by doing the thing -- loading the extension, listing
    the bucket, reading the catalog config -- because a configured variable is
    not the same fact as a reachable service.
    """
    import os

    from . import engine

    if install:
        os.environ["P8_LAKE_INSTALL_EXTENSIONS"] = "1"
    report: dict[str, object] = {}
    ok = True
    try:
        import duckdb
        report["duckdb"] = duckdb.__version__
    except ModuleNotFoundError:
        typer.echo(json.dumps({"duckdb": "not installed: pip install 'percolate-core[lake]'"}))
        raise typer.Exit(1)

    con = duckdb.connect()
    for ext in engine.EXTENSIONS:
        try:
            engine._load(con, ext)
            report[ext] = "ok"
        except Exception as e:  # noqa: BLE001
            report[ext] = str(e).splitlines()[0]
            ok = False

    cfg = engine.lake()
    if cfg is None:
        report["object_storage"] = ("not configured (P8_S3_KEY/P8_S3_SECRET unset): refine "
                                    "steps can take inline rows and land them, nothing more")
    else:
        try:
            c = engine.connect(cfg, ("httpfs",))
            c.execute(f"select count(*) from glob({engine.q(cfg.uri('*'))})").fetchone()
            report["object_storage"] = f"ok: {cfg.endpoint} bucket {cfg.bucket}"
        except Exception as e:  # noqa: BLE001
            report["object_storage"] = str(e).splitlines()[0]
            ok = False
        if cfg.catalog_url:
            try:
                engine.catalog_table(cfg, "p8_doctor.none")
                report["catalog"] = f"ok: {cfg.catalog_url} warehouse {cfg.warehouse}"
            except Exception as e:  # noqa: BLE001
                report["catalog"] = str(e).splitlines()[0]
                ok = False
        else:
            report["catalog"] = "not configured (P8_LAKE_CATALOG_URL): parquet outputs only"
    typer.echo(json.dumps(report, indent=2))
    raise typer.Exit(0 if ok else 1)
