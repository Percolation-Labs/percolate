"""The `refine` op: inputs by name, one SELECT, a dataset and a bounded landing.

    - id: clean
      work: true
      queue: lake
      input:
        op: refine
        inputs:
          raw:   {dataset: shipments_raw}                     # Parquet or Iceberg
          ports: {dataset: ports}
          watch: {rows: '{{steps.watchlist.result.rows}}'}    # the small Postgres side
          near:  {nearest: {dataset: notes, column: emb, k: 20,
                            vector: '{{steps.q.result.embedding}}',
                            model: text-embedding-3-small}}
        sql: |
          select s.*, ST_Point(s.lon, s.lat) as geom
          from raw s join watch w using (carrier)
          where s.shipped_at >= $since
        params: {since: '{{run.since}}'}
        embed:  {column: summary, into: summary_emb,
                 model: text-embedding-3-small, max_rows: 5000}
        output: {dataset: shipments_clean, format: iceberg, mode: merge, key: [id]}
        land:   {function: land_shipments, max_rows: 2000}

WHAT GOES WHERE. Postgres decides what the run owner may read and where the
output may live (lake.sql). DuckDB, in a sealed connection, reads exactly those
locations and runs the one SELECT. This module then writes -- the output
dataset, and at most `max_rows` rows into Postgres through an allow-listed
function. Nothing authored ever writes.

RETRIES ARE SAFE BY CONSTRUCTION, because a work step is retried: a Parquet
append is written at a key named by the task, a replace into a directory named
by the task, and an Iceberg append deletes this task's earlier rows (by a
`_p8_task` column) in the same transaction that inserts them. A landing
function is handed the task id and should upsert.
"""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any

from ..core import as_service
from ..worker.templates import TerminalError
from . import engine, guard
from .engine import q, qi

__all__ = ["refine"]

_IDENT = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
_MAX_NEAREST = 10_000
_MAX_LAND_BATCH = 10_000   # content.lake_land's own per-call cap


# ------------------------------------------------------------------ the plan

def _check_ident(what: str, name: Any) -> str:
    if not isinstance(name, str) or not _IDENT.match(name):
        raise TerminalError(f"{what} must be a lowercase identifier, got {name!r}")
    return name


def _positive(what: str, value: Any, required: bool = True) -> int | None:
    if value is None and not required:
        return None
    try:
        n = int(value)
    except (TypeError, ValueError):
        n = 0
    if n <= 0:
        raise TerminalError(
            f"{what} is required and must be a positive integer -- it is the bound that "
            "stops a forgotten WHERE from costing the database, the way max_fanout does "
            "for a matrix")
    return n


def _dataset_names(inputs: dict[str, Any]) -> list[str]:
    names = set()
    for alias, src in inputs.items():
        _check_ident("an input alias", alias)
        if not isinstance(src, dict) or len([k for k in ("dataset", "rows", "nearest") if k in src]) != 1:
            raise TerminalError(
                f"input {alias!r} must be exactly one of {{dataset: name}}, {{rows: [...]}} "
                "or {nearest: {...}}")
        if "dataset" in src:
            names.add(str(src["dataset"]))
        elif "nearest" in src:
            names.add(str((src["nearest"] or {}).get("dataset")))
    return sorted(names)


def _vector_literal(vec: Any, dims: int) -> str:
    """A query vector as a DuckDB literal. Numbers only, so it cannot be SQL."""
    if not isinstance(vec, list) or len(vec) != dims:
        raise TerminalError(
            f"the query vector has {len(vec) if isinstance(vec, list) else 'no'} "
            f"dimensions and the column has {dims}")
    try:
        nums = [float(x) for x in vec]
    except (TypeError, ValueError):
        raise TerminalError("the query vector must be a list of numbers") from None
    return "[" + ",".join(repr(x) for x in nums) + f"]::FLOAT[{dims}]"


def _read_expr(d: dict[str, Any], iceberg: dict[str, dict[str, str]]) -> tuple[str, str]:
    """(SQL that reads dataset d with its registered types restored, allowed location).

    The registry is what makes the round trip lossless. Parquet and Iceberg both
    hand back an embedding as FLOAT[] (measured: FLOAT[3] written, FLOAT[] read)
    and Iceberg holds geometry only as WKB, so the view casts the columns the
    registry declares back to FLOAT[N] and GEOMETRY. Authored SQL then sees the
    types the data was written with, whichever format it was written in.
    """
    if d["format"] == "iceberg":
        meta = iceberg[d["name"]]
        source = f"iceberg_scan({q(meta['metadata_location'])})"
        location = meta["location"]
    else:
        location = f"s3://{d['bucket']}/{d['prefix']}/"
        source = f"read_parquet({q(location + '*.parquet')})"
    replace = []
    for col, g in (d.get("geometry") or {}).items():
        if (g or {}).get("encoding") == "wkb":
            crs = (g or {}).get("crs")
            typed = f"::GEOMETRY({q(_crs(crs))})" if crs else ""
            replace.append(f"ST_GeomFromWKB({qi(col)}){typed} as {qi(col)}")
    for col, e in (d.get("embeddings") or {}).items():
        replace.append(f"{qi(col)}::FLOAT[{int(e['dims'])}] as {qi(col)}")
    # _p8_task is how an Iceberg append is made idempotent (_write_iceberg), not
    # data, so a reader never sees it. EXCLUDE before REPLACE: DuckDB's order.
    hidden = " exclude (_p8_task)" if d["format"] == "iceberg" and any(
        c.get("name") == "_p8_task" for c in d.get("columns") or []) else ""
    star = "*" + hidden + (" replace (" + ", ".join(replace) + ")" if replace else "")
    return f"select {star} from {source}", location


# ------------------------------------------------------------------ the sealed half

def _describe(con, relation: str) -> list[dict[str, str]]:
    return [{"name": r[0], "type": r[1]}
            for r in con.execute(f"describe {relation}").fetchall()]


_CRS = re.compile(r"^[A-Za-z][A-Za-z0-9]*:[A-Za-z0-9._-]+$")


def _crs(value: Any) -> str:
    """An authority:code CRS name (OGC:CRS84, EPSG:27700), or a refusal. It is
    interpolated into a type, so it is checked, not trusted."""
    if not isinstance(value, str) or not _CRS.match(value):
        raise TerminalError(f"a CRS is an authority:code name like OGC:CRS84 or EPSG:27700, got {value!r}")
    return value


def _typed_crs(type_name: str) -> str | None:
    m = re.search(r"GEOMETRY\('([^']+)'\)", type_name, re.I)
    return m.group(1) if m else None


def _pin_crs(con, columns: list[dict[str, str]], declared: dict[str, Any]) -> bool:
    """Give every GEOMETRY column of the result the CRS it really has. True if any changed.

    A CRS IS A DECLARATION, NOT A GUESS -- sources.md §13.5's rule for epoch
    scale, and for the same reason. ST_Point returns GEOMETRY with no CRS, and
    Parquet writes such a column as OGC:CRS84 (longitude/latitude degrees)
    whatever it holds: British National Grid metres, written untyped, read
    back as GEOMETRY('OGC:CRS84'). Every distance and containment test over
    that file is then wrong with no error. So a column the type does not pin
    must be declared, the declaration is cast onto the column before anything
    is written, and a declaration that contradicts the type is refused.
    """
    fixes = []
    for c in columns:
        if not c["type"].upper().startswith("GEOMETRY"):
            continue
        typed = _typed_crs(c["type"])
        stated = ((declared or {}).get(c["name"]) or {}).get("crs")
        if typed and stated and typed != stated:
            raise TerminalError(
                f"column {c['name']} is {c['type']} and the step declares crs {stated!r}")
        if not typed and not stated:
            raise TerminalError(
                f"column {c['name']} is GEOMETRY with no CRS, and Parquet would record it as "
                "OGC:CRS84 (longitude/latitude) whatever it holds. Declare it: "
                f"`output: {{geometry: {{{c['name']}: {{crs: OGC:CRS84}}}}}}`, or the CRS it "
                "is really in")
        if not typed:
            fixes.append(f"{qi(c['name'])}::GEOMETRY({q(_crs(stated))}) as {qi(c['name'])}")
    if fixes:
        con.execute("create or replace table refined as select * replace ("
                    + ", ".join(fixes) + ") from refined")
    return bool(fixes)


def _geometry_of(columns: list[dict[str, str]], encoding: str) -> dict[str, Any]:
    """Every GEOMETRY column and its CRS, read off the type _pin_crs settled."""
    return {c["name"]: {"encoding": encoding, "crs": _typed_crs(c["type"])}
            for c in columns if c["type"].upper().startswith("GEOMETRY")}


def _embeddings_of(columns: list[dict[str, str]], resolved: list[dict[str, Any]],
                   embedded: dict[str, Any] | None,
                   declared: dict[str, str]) -> dict[str, Any]:
    """Which array columns are vectors, and in whose space.

    A column carries its model forward from an input of the same name, unless
    two inputs disagree about it -- then it carries nothing, rather than a guess,
    and the step can say. The registry refuses a model that is not registered or
    a width it does not produce (lake.sql §4), so a wrong answer here fails
    there rather than ranking against the wrong space later.
    """
    known: dict[str, dict[str, Any] | None] = {}
    for d in resolved:
        for col, e in (d.get("embeddings") or {}).items():
            if col in known and known[col] != e:
                known[col] = None
            else:
                known.setdefault(col, e)
    types = {c["name"]: c["type"] for c in columns}
    out: dict[str, Any] = {}
    for col, e in known.items():
        if e and col in types and types[col].upper().startswith("FLOAT["):
            out[col] = e
    for col, model in (declared or {}).items():
        m = re.match(r"FLOAT\[(\d+)\]", types.get(col, ""), re.I)
        if not m:
            raise TerminalError(
                f"`embeddings:` names column {col!r}, which is not a FLOAT[N] column of the result")
        out[col] = {"model": model, "dims": int(m.group(1))}
    if embedded:
        out[embedded["column"]] = {"model": embedded["model"], "dims": embedded["dims"]}
    return out


def _sealed(plan: dict[str, Any]) -> dict[str, Any]:
    """Open the sealed connection, run the SELECT, embed, count. Returns state."""
    cfg = plan["cfg"]
    con = engine.connect(cfg)
    allowed: list[str] = []
    try:
        by_name = {d["name"]: d for d in plan["resolved"]}
        for alias, src in plan["inputs"].items():
            if "rows" in src:
                import pyarrow as pa
                rows = src["rows"]
                if not isinstance(rows, list) or not rows or not all(isinstance(r, dict) for r in rows):
                    raise TerminalError(
                        f"input {alias!r}: `rows` must be a non-empty list of objects -- an "
                        "empty list has no columns to join on. Guard the step with a "
                        "condition, or select at least one row")
                con.register(alias, pa.Table.from_pylist(rows))
                continue
            if "dataset" in src:
                expr, location = _read_expr(by_name[str(src["dataset"])], plan["iceberg"])
            else:
                n = src["nearest"] or {}
                d = by_name[str(n.get("dataset"))]
                col = str(n.get("column"))
                e = (d.get("embeddings") or {}).get(col)
                if not e:
                    raise TerminalError(
                        f"dataset {d['name']!r} has no embedding column {col!r} in the registry")
                # THE MODEL NAMES THE SPACE -- the same refusal aiq makes at
                # compile time, for the same reason: two models of one width
                # produce vectors that rank against each other with no error.
                if n.get("model") != e["model"]:
                    raise TerminalError(
                        f"the query vector is from {n.get('model')!r} and "
                        f"{d['name']}.{col} is in {e['model']!r}'s space -- embed the query "
                        "with the column's model")
                k = min(_positive("nearest.k", n.get("k", 10)), _MAX_NEAREST)
                base, location = _read_expr(d, plan["iceberg"])
                vec = _vector_literal(n.get("vector"), int(e["dims"]))
                expr = (f"select *, array_cosine_distance({qi(col)}, {vec}) as _distance "
                        f"from ({base}) order by _distance limit {k}")
            con.execute(f"create view {qi(alias)} as {expr}")
            allowed.append(location)

        if plan["output"]:
            allowed.append(plan["write_dir"])
        dirs = engine.seal(con, allowed)

        try:
            con.sql(plan["sql"], params=plan["params"] or None).to_table("refined")
        except TerminalError:
            raise
        except Exception as e:  # noqa: BLE001 -- binder, IO and permission errors all
            # mean the authored SQL cannot run over these inputs, on any attempt
            raise TerminalError(f"the refine SQL failed: {str(e).splitlines()[0]}") from None

        rows = con.execute("select count(*) from refined").fetchone()[0]
        embedded = None
        if plan["embed"]:
            embedded = _embed(con, plan["embed"], plan["embed_call"], rows)
        columns = _describe(con, "refined")
        if plan["output"] and _pin_crs(con, columns, plan["output"].get("geometry") or {}):
            columns = _describe(con, "refined")
        return {"con": con, "rows": rows, "columns": columns, "allowed": dirs,
                "embedded": embedded}
    except BaseException:
        con.close()
        raise


def _embed(con, spec: dict[str, Any], call: dict[str, Any], rows: int) -> dict[str, Any]:
    """Add a vector column for a text column, in one model's space.

    Batched by ingest/embed.embed_texts -- the same code, the same registry row
    and the same response checks the corpus pipeline uses, so a provider that
    works for chunks works here. Bounded by `max_rows` because every row is a
    model call's worth of spend.
    """
    import pyarrow as pa

    from ..ingest.embed import embed_texts

    column = spec["column"]
    limit = _positive("embed.max_rows", spec.get("max_rows"))
    if rows > limit:
        raise TerminalError(
            f"the refined result has {rows} rows and embed.max_rows is {limit}; nothing "
            "was embedded or written")
    # to_arrow_table, not arrow(): on DuckDB 1.5 `.arrow()` is a
    # RecordBatchReader, and this needs a Table to append a column to.
    table = con.execute("select * from refined").to_arrow_table()
    if column not in table.column_names:
        raise TerminalError(f"embed.column {column!r} is not a column of the result")
    texts = table.column(column).to_pylist()
    present = [i for i, t in enumerate(texts) if t is not None and str(t).strip()]
    vectors, requests = embed_texts(call, [str(texts[i]) for i in present]) if present else ([], 0)
    dims = len(vectors[0]) if vectors else int(call.get("dim") or 0)
    if dims <= 0:
        raise TerminalError("the embedding model's width is unknown and nothing came back to measure")
    full: list[list[float] | None] = [None] * len(texts)
    for i, v in zip(present, vectors):
        full[i] = v
    table = table.append_column(spec["into"], pa.array(full, type=pa.list_(pa.float32(), dims)))
    con.register("refined_embedded", table)
    con.execute("drop table refined")
    con.execute("create table refined as select * from refined_embedded")
    con.unregister("refined_embedded")
    return {"column": spec["into"], "model": call["model"], "dims": dims,
            "rows": len(present), "requests": requests}


# ------------------------------------------------------------------ writing

def _write_parquet(state: dict[str, Any], plan: dict[str, Any]) -> dict[str, Any]:
    cfg, con, task = plan["cfg"], state["con"], plan["task"]
    key = f"{plan['prefix']}/{task}.parquet" if plan["mode"] == "append" else \
          f"{plan['prefix']}/part-0.parquet"
    con.execute(f"copy refined to {q(cfg.uri(key))} (format parquet, compression zstd)")
    glob = cfg.uri(plan["prefix"] + "/*.parquet")
    total = con.execute(f"select count(*) from read_parquet({q(glob)})").fetchone()[0]
    files = con.execute(f"select count(*) from glob({q(glob)})").fetchone()[0]
    return {"bucket": cfg.bucket, "prefix": plan["prefix"], "row_count": total,
            "file_count": files, "written": cfg.uri(key)}


def _write_iceberg(state: dict[str, Any], plan: dict[str, Any]) -> dict[str, Any]:
    """Stage as Parquet from the sealed side, commit from the unsealed side.

    The sealed connection cannot reach the catalog, by design, so it writes the
    result under the output's own prefix and a second connection -- one that
    has never run authored SQL -- moves it into the table in one transaction.
    Iceberg cannot hold GEOMETRY or FLOAT[N] (lake.md §4), so shapes go in as
    WKB and vectors as FLOAT[]; the registry records both for the way back.
    """
    cfg, sealed, task = plan["cfg"], state["con"], plan["task"]
    staged = cfg.uri(f"{plan['prefix']}/_staging/{task}.parquet")
    sealed.execute(f"copy refined to {q(staged)} (format parquet, compression zstd)")

    select = []
    for c in state["columns"]:
        t = c["type"].upper()
        if t.startswith("GEOMETRY"):
            select.append(f"ST_AsWKB({qi(c['name'])}) as {qi(c['name'])}")
        elif re.match(r"FLOAT\[\d+\]$", t):
            select.append(f"{qi(c['name'])}::FLOAT[] as {qi(c['name'])}")
        else:
            select.append(qi(c["name"]))
    if plan["mode"] == "append":
        select.append(f"{q(task)} as _p8_task")
    source = f"select {', '.join(select)} from read_parquet({q(staged)})"

    ns, _, name = plan["table_ref"].partition(".")
    table = f"ice.{qi(ns)}.{qi(name)}"
    mod = engine.connect(cfg)
    try:
        engine.attach_catalog(mod, cfg)
        mod.execute(f"create schema if not exists ice.{qi(ns)}")
        if engine.catalog_table(cfg, plan["table_ref"]) is None:
            mod.execute(f"create table {table} as {source}")
        else:
            have = {r[0] for r in mod.execute(f"describe {table}").fetchall()}
            mod.execute(f"create temp view incoming as {source}")
            # Schema evolution, in the one direction that cannot lose data:
            # a new column is added; a vanished one stays, and is null in new rows.
            for col, typ in mod.execute("select column_name, column_type from (describe incoming)").fetchall():
                if col not in have:
                    mod.execute(f"alter table {table} add column {qi(col)} {typ}")
            if plan["mode"] == "merge":
                on = " and ".join(f"t.{qi(k)} = s.{qi(k)}" for k in plan["key"])
                mod.execute(f"merge into {table} as t using incoming as s on ({on}) "
                            "when matched then update set * when not matched then insert *")
            else:
                mod.execute("begin")
                if plan["mode"] == "append":
                    mod.execute(f"delete from {table} where _p8_task = {q(task)}")
                else:
                    mod.execute(f"delete from {table}")
                mod.execute(f"insert into {table} by name select * from incoming")
                mod.execute("commit")
        total = mod.execute(f"select count(*) from {table}").fetchone()[0]
    finally:
        mod.close()
    _remove(cfg, f"{plan['prefix']}/_staging/{task}.parquet")
    meta = engine.catalog_table(cfg, plan["table_ref"]) or {}
    location = meta.get("location", "")
    bucket, _, prefix = location.removeprefix("s3://").partition("/")
    return {"bucket": bucket or cfg.bucket, "prefix": prefix or plan["prefix"],
            "row_count": total, "file_count": 0, "written": plan["table_ref"]}


def _remove(cfg, key: str) -> None:
    """Delete a staged object. DuckDB has no way to delete from S3, so boto3."""
    try:
        from ..content import storage
        storage.client().delete_object(Bucket=cfg.bucket, Key=key)
    except Exception:  # noqa: BLE001 -- a leftover staging file is litter, not a
        pass           # failure of the step; `_staging/` is never globbed by a reader


def _landing_rows(state: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    """The result as JSON objects, geometry as GeoJSON. Bounded by max_rows,
    which was checked against the count before anything was written."""
    replace = [f"ST_AsGeoJSON({qi(c['name'])})::json as {qi(c['name'])}"
               for c in state["columns"] if c["type"].upper().startswith("GEOMETRY")]
    star = "*" + (" replace (" + ", ".join(replace) + ")" if replace else "")
    got = state["con"].execute(
        f"select to_json(r)::varchar from (select {star} from refined limit {limit}) r").fetchall()
    return [json.loads(r[0]) for r in got]


# ------------------------------------------------------------------ the op

async def _duck(fn, *args: Any) -> Any:
    """Run a DuckDB phase off the event loop, with its failures classified.

    I/O is the one DuckDB failure worth retrying -- a store that timed out may
    answer the second time. Everything else DuckDB raises (a permission the
    seal refused, a binder error, a setting it will not take) is the same on
    every attempt, and the first end-to-end run spent five attempts per step
    learning that about a setting.
    """
    import duckdb

    try:
        return await asyncio.to_thread(fn, *args)
    except duckdb.IOException:
        raise
    except duckdb.Error as e:
        raise TerminalError(f"{type(e).__name__}: {str(e).splitlines()[0]}") from None


async def _call(conn, sql: str, *args: Any) -> Any:
    """One lake function, with its refusals made terminal.

    `raise exception` in lake.sql is a statement about the definition or about
    permissions -- no such dataset for this owner, a location outside the org,
    a model that is not registered -- and none of them changes on the fifth
    attempt. Connection and serialisation failures stay retryable.
    """
    import asyncpg

    try:
        raw = await conn.fetchval(sql, *args)
    except (asyncpg.RaiseError, asyncpg.InsufficientPrivilegeError,
            asyncpg.CheckViolationError, asyncpg.UndefinedFunctionError) as e:
        raise TerminalError(str(e)) from None
    return json.loads(raw) if isinstance(raw, str) else raw


async def refine(spec: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    task, worker = str(ctx["_task_id"]), str(ctx["_worker_id"])

    # A TEMPLATE IN THE SQL IS REFUSED, and the check reads the UNRESOLVED input
    # because by now the worker has substituted it. `where site = '{{run.site}}'`
    # makes run input a fragment of SQL; YAML.md refuses that for sql steps and
    # this is the same rule. Values travel in `params:` and bind as $name.
    raw_sql = (ctx.get("task_input") or {}).get("sql")
    if isinstance(raw_sql, str) and "{{" in raw_sql:
        raise TerminalError(
            "the refine SQL contains a {{template}}; a template in a statement would be "
            "a fragment of SQL. Put the value in `params:` and write $name in the SQL")
    sql = guard.single_select(spec.get("sql"))
    params = spec.get("params") or {}
    if not isinstance(params, dict):
        raise TerminalError("`params:` is a map of name to value, bound as $name")
    inputs = spec.get("inputs") or {}
    if not isinstance(inputs, dict):
        raise TerminalError("`inputs:` is a map of alias to source")
    output, land, embed = spec.get("output"), spec.get("land"), spec.get("embed")
    if not output and not land:
        raise TerminalError(
            "a refine step with neither `output:` nor `land:` computes a result and keeps "
            "none of it")

    names = _dataset_names(inputs)
    cfg = engine.lake()
    if cfg is None and (output or names):
        raise TerminalError(
            "this step reads or writes a dataset and the lake worker has no object storage: "
            "set P8_S3_ENDPOINT, P8_S3_KEY and P8_S3_SECRET as for the Content Server. "
            "Without them a refine step can only take inline `rows:` and `land:` them")

    plan: dict[str, Any] = {"cfg": cfg, "task": task, "sql": sql, "params": params,
                            "inputs": inputs, "output": output, "embed": None,
                            "iceberg": {}, "resolved": []}

    if output:
        if not isinstance(output, dict):
            raise TerminalError("`output:` is {dataset, format, mode, key?, visibility?}")
        _check_ident("output.dataset", output.get("dataset"))
        fmt = output.get("format", "parquet")
        mode = output.get("mode", "append")
        if fmt not in ("parquet", "iceberg"):
            raise TerminalError(f"output.format is parquet or iceberg, got {fmt!r}")
        if mode not in ("append", "replace", "merge"):
            raise TerminalError(f"output.mode is append, replace or merge, got {mode!r}")
        if mode == "merge" and fmt != "iceberg":
            raise TerminalError(
                "merge needs row identity, and Parquet under a prefix has none -- use "
                "format: iceberg, or mode: replace")
        key = output.get("key") or []
        if mode == "merge" and not key:
            raise TerminalError("mode: merge needs `key:`, the columns a row is matched on")
        plan.update(format=fmt, mode=mode, key=[str(k) for k in key])

    if land:
        if not isinstance(land, dict) or not land.get("function"):
            raise TerminalError("`land:` is {function, max_rows, batch_rows?}")
        plan["land_max"] = _positive("land.max_rows", land.get("max_rows"))
        plan["land_batch"] = min(_positive("land.batch_rows", land.get("batch_rows", 1000)),
                                 _MAX_LAND_BATCH)

    if embed:
        if not isinstance(embed, dict) or not embed.get("column") or not embed.get("model"):
            raise TerminalError("`embed:` is {column, into, model, max_rows}")
        _check_ident("embed.into", embed.get("into"))
        _positive("embed.max_rows", embed.get("max_rows"))
        plan["embed"] = embed

    # ---- Postgres: what the run owner may read, and where the output goes.
    async with as_service() as conn:
        if names:
            plan["resolved"] = await _call(
                conn, "select content.lake_resolve($1::uuid, $2, $3::text[])::text",
                task, worker, names)
        if output:
            target = await _call(
                conn, "select content.lake_target($1::uuid, $2, $3, $4)::text",
                task, worker, output["dataset"], plan["format"])
            existing = target.get("existing") or {}
            if plan["format"] == "parquet":
                if plan["mode"] == "replace":
                    plan["prefix"] = f"{target['prefix']}/v-{task}"
                else:
                    plan["prefix"] = existing.get("prefix") or target["prefix"]
            else:
                plan["prefix"] = target["prefix"]
            plan["table_ref"] = target["table_ref"]
            plan["write_dir"] = cfg.uri(plan["prefix"] + "/")
        if embed:
            plan["embed_call"] = await _call(
                conn, "select aiq.embed_batch_call($1, $2::jsonb)::text",
                embed["model"], ["probe"])

    for d in plan["resolved"]:
        if d["format"] == "iceberg":
            meta = await asyncio.to_thread(engine.catalog_table, cfg, d["table_ref"])
            if meta is None:
                raise TerminalError(
                    f"dataset {d['name']} is registered as {d['table_ref']} and the catalog "
                    "has no such table")
            plan["iceberg"][d["name"]] = meta

    # ---- DuckDB: the sealed half, then the checks, then the writes.
    state = await _duck(_sealed, plan)
    try:
        receipt: dict[str, Any] = {"rows": state["rows"], "allowed": state["allowed"]}
        if state["embedded"]:
            receipt["embedded"] = state["embedded"]

        # Every bound is checked BEFORE the first write, so a step that is
        # refused has written nothing anywhere.
        if land and state["rows"] > plan["land_max"]:
            raise TerminalError(
                f"the refined result has {state['rows']} rows and land.max_rows is "
                f"{plan['land_max']}; nothing was written to the lake or to Postgres. "
                "Narrow the SELECT, or write the result to `output:` and land less of it")

        if output:
            writer = _write_iceberg if plan["format"] == "iceberg" else _write_parquet
            wrote = await _duck(writer, state, plan)
            geometry = _geometry_of(state["columns"],
                                    "wkb" if plan["format"] == "iceberg" else "native")
            embeddings = _embeddings_of(state["columns"], plan["resolved"],
                                        state["embedded"], output.get("embeddings") or {})
            async with as_service() as conn:
                receipt["output"] = await _call(
                    conn, "select content.register_lake_output($1::uuid, $2, $3::jsonb)::text",
                    task, worker,
                    {"name": output["dataset"], "format": plan["format"],
                     "mode": plan["mode"], "bucket": wrote["bucket"],
                     "prefix": wrote["prefix"], "table_ref": plan["table_ref"]
                     if plan["format"] == "iceberg" else None,
                     "columns": state["columns"], "row_count": wrote["row_count"],
                     "file_count": wrote["file_count"], "geometry": geometry,
                     "embeddings": embeddings, "inputs": names,
                     "visibility": output.get("visibility", "private")})
            receipt["output"]["written"] = wrote["written"]
            receipt["output"]["row_count"] = wrote["row_count"]

        if land:
            rows = await _duck(_landing_rows, state, plan["land_max"])
            batch, results = plan["land_batch"], []
            # ONE TRANSACTION for every batch: a landing that fails part way
            # lands nothing, and the retry starts from the same empty slate.
            async with as_service() as conn:
                for i in range(0, len(rows), batch):
                    results.append(await _call(
                        conn, "select content.lake_land($1::uuid, $2, $3, $4::jsonb)::text",
                        task, worker, land["function"], rows[i:i + batch]))
            receipt["landed"] = {"function": land["function"], "rows": len(rows),
                                 "batches": len(results),
                                 "last": results[-1] if results else None}
        return {"result": receipt}
    finally:
        state["con"].close()
