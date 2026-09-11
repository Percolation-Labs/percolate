"""The `query` op: run a p8ql LAKE query for a workflow step.

    - id: totals
      p8ql: 'LAKE FROM watched select carrier, count(*) from watched group by 1'

compiles (in the parser crate) to

    - id: totals
      work: true
      queue: lake
      input: {op: query, p8ql: 'LAKE FROM watched select ...'}

and this is what runs it. The plan comes from the parser itself (`aiq_parse`)
rather than from a second parser here, so the dataset list and the row cap are
the ones a caller saw when aiq.query planned the same string. Each dataset is
a view under its own name, resolved for the run owner, inside the same seal a
refine step runs in.

A LAKE query READS. Its result is at most the plan's row cap (1000), and a
result over the engine's payload cap is offloaded as an artifact by the worker
loop like any other step's. Work that writes, or that needs values from the
run, is a `refine` step: a LAKE query refuses templates, because the worker
would splice them into the SQL as text.
"""

from __future__ import annotations

import base64
import datetime as dt
import decimal
import json
import uuid
from typing import Any

from ..core import as_service
from ..worker.templates import TerminalError
from . import engine, guard
from .engine import qi
from .refine import _call, _duck, _read_expr

__all__ = ["query"]


def _json_value(v: Any) -> Any:
    if isinstance(v, (dt.datetime, dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, decimal.Decimal):
        return float(v)
    if isinstance(v, uuid.UUID):
        return str(v)
    if isinstance(v, (bytes, bytearray, memoryview)):
        return base64.b64encode(bytes(v)).decode()
    if isinstance(v, dict):
        return {k: _json_value(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_json_value(x) for x in v]
    return v


def _run(cfg, resolved: dict[str, dict], iceberg: dict, statement: str, cap: int) -> dict:
    con = engine.connect(cfg)
    try:
        locations = []
        for name, d in resolved.items():
            expr, location = _read_expr(d, iceberg)
            con.execute(f"create view {qi(name)} as {expr}")
            locations.append(location)
        engine.seal(con, locations)
        try:
            rel = con.sql(statement)
            # Shapes leave as GeoJSON: a GEOMETRY value has no JSON form of its
            # own, and a successor reading {{steps.x.result.rows}} wants one.
            exprs = [f"ST_AsGeoJSON({qi(c)})::json as {qi(c)}" if str(t).upper().startswith("GEOMETRY")
                     else qi(c) for c, t in zip(rel.columns, rel.types)]
            rel = rel.project(", ".join(exprs))
            columns = [{"name": c, "type": str(t)} for c, t in zip(rel.columns, rel.types)]
            got = rel.limit(cap + 1).fetchall()
        except TerminalError:
            raise
        except Exception as e:  # noqa: BLE001 -- a binder or permission error is the SQL's
            raise TerminalError(f"the LAKE query failed: {str(e).splitlines()[0]}") from None
    finally:
        con.close()
    json_cols = {c["name"] for c in columns if c["type"].upper() == "JSON"}
    rows = [{c["name"]: (json.loads(v) if c["name"] in json_cols and isinstance(v, str) else _json_value(v))
             for c, v in zip(columns, r)} for r in got[:cap]]
    return {"columns": columns, "rows": rows, "truncated": len(got) > cap}


async def query(spec: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    task, worker = str(ctx["_task_id"]), str(ctx["_worker_id"])
    # The compiler refuses a template in a LAKE query; this catches a
    # hand-written work step that carries one, reading the UNRESOLVED input.
    raw = (ctx.get("task_input") or {}).get("p8ql")
    if isinstance(raw, str) and "{{" in raw:
        raise TerminalError(
            "a LAKE query cannot carry a {{template}} -- it would be spliced into the SQL as "
            "text. Use op: refine, whose `params:` bind as $name")
    text = spec.get("p8ql")
    if not isinstance(text, str) or not text.strip():
        raise TerminalError("op: query needs `p8ql:`, a LAKE query")

    async with as_service() as conn:
        plan = await _call(conn, "select aiq_parse($1)::text", text)
    if not plan.get("ok"):
        raise TerminalError(f"p8ql parse error: {plan.get('error')}")
    if plan.get("mode") != "LAKE":
        raise TerminalError(
            f"op: query runs LAKE queries, and this is {plan.get('mode')} -- which runs in "
            "Postgres as an ordinary p8ql: step")
    statement = guard.single_select(plan.get("arg"))
    names = list(dict.fromkeys(plan.get("sources") or []))
    cap = int(plan.get("limit") or 1000)

    cfg = engine.lake()
    if cfg is None:
        raise TerminalError(
            "a LAKE query reads object storage and this lake worker has none configured: "
            "set P8_S3_ENDPOINT, P8_S3_KEY and P8_S3_SECRET")
    async with as_service() as conn:
        resolved = {d["name"]: d for d in await _call(
            conn, "select content.lake_resolve($1::uuid, $2, $3::text[])::text",
            task, worker, names)}
    iceberg = {}
    for d in resolved.values():
        if d["format"] == "iceberg":
            meta = engine.catalog_table(cfg, d["table_ref"])
            if meta is None:
                raise TerminalError(
                    f"dataset {d['name']} is registered as {d['table_ref']} and the catalog has no such table")
            iceberg[d["name"]] = meta

    out = await _duck(_run, cfg, resolved, iceberg, statement, cap)
    return {"result": {"mode": "LAKE", **out, "row_count": len(out["rows"]),
                       # Provenance for whatever cites this: which datasets, at
                       # which registry version, answered. Not where they are.
                       "sources": [{"dataset": d["name"], "format": d["format"],
                                    "row_count": d.get("row_count"), "updated_at": d.get("updated_at")}
                                   for d in resolved.values()]}}
