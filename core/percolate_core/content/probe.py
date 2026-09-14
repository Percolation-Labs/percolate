"""Look at an endpoint once, and report what came back rather than what a model expects.

The API source assistant could design a complete incremental pull -- watermarks,
pagination, dot-path mappings, casts -- and could not find out anything about
the API it was designing for. Its prompt said so: *"If the API contract is
unknown, configuration_json may be empty: ask for the endpoint documentation or
a sample response instead of inventing paths"*, and *"Do not claim to browse or
discover arbitrary APIs."* Two contracts were hardcoded into it so that the
"show me an example" path had something true to say.

That prompt was defending against the right failure. A model asked for
`records_path` and `id_path` with nothing to read will produce plausible ones,
and a plausible dot path fails on the first pull, after the source is saved,
with an error about a missing field. This module removes the defence by
removing its cause: one bounded GET, and the paths come from the response.

WHAT IT WILL NOT DO. It reports; it does not decide. The report separates what
was **observed** in the bytes from what was **inferred** from names and shapes,
because those are different kinds of claim and the operator is about to correct
one of them. `watermark_param` -- the *request* parameter that filters by the
watermark -- is in neither: a single response cannot show it, so it is listed as
friction rather than guessed, which is exactly the guess that used to fail.

WHY IT LIVES IN `content` AND NOT BESIDE THE PULLER. This is the process
allowed to make a request to somewhere else -- the scraper and `http_call`
steps are here for that reason -- and `ingest` drags a parser per file format
behind it that a content deployment does not install. What it must not do is
carry its own idea of which URLs may be fetched and where a named credential
may go: those come from `core.credentials`, the one origin parser in the
package, which `ingest/api.py` wraps for the puller with the same fragment
rule applied below. Two callers of one parser; not two rules.

A probe of an authenticated endpoint takes a `credential_ref` and resolves it
here, service-side, against the operator's origin bindings. A value pasted into
the browser has nowhere to go, by construction.

WHY NOT A SECOND OPENAPI PARSER. If the document at the URL is OpenAPI or
Swagger, `agentic/tools/openapi.py` already turns it into canonical tools and is
the parser this collection maintains. The probe hands the URL to it and reports
its operations. `brief.md` §5.2 is the reason it cannot be the other way round.
"""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any
from urllib.parse import parse_qsl, urljoin, urlsplit

import httpx

from ..core import TerminalError, credential_for
from ..core.credentials import origin as credential_origin
from ..core.egress import refuse_internal_egress

USER_AGENT = "Percolate-Source-Probe (+https://percolate.sh; one request per inspection)"
"""Identifying, and it says what it is doing. An endpoint's operator should be
able to tell this apart from a crawler in one line of their access log."""

TIMEOUT = 20.0
MAX_BYTES = 2_000_000
"""Enough to see the shape of a page; small enough that a probe of a large
export is refused rather than pulled. Reading more would make this an ingestion
that nobody asked for."""

MAX_REDIRECTS = 3

ANONYMOUS = ("Accept", "User-Agent")
"""The headers a hop to another origin carries. A named credential is bound to
the origin the operator named, and a redirect is the endpoint choosing where to
send it next."""

MAX_RECORDS = 60
MAX_FIELDS = 80

ISO = re.compile(r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}|$)")
DATEY = re.compile(r"(date|time|_at$|^at$|created|updated|modified|published|timestamp|changed)", re.I)
IDY = re.compile(r"(^id$|_id$|^guid|uuid|^key$|^slug$|^code$|^number$|^sha|hash)", re.I)


class ProbeFailed(TerminalError):
    """The endpoint could not be read. Carries what was seen, never a guess."""


def origin(url: str) -> tuple:
    """The one origin parser, plus the fragment rule a source configuration adds.

    Identical to `ingest/api.py`'s wrapper, and deliberately so: a URL this
    refuses is a URL the puller would refuse, and a probe that accepted one
    would produce a configuration that cannot run.
    """
    try:
        if urlsplit(url).fragment:
            raise ValueError
        return credential_origin(url)
    except ValueError:
        raise ProbeFailed(
            "Use an HTTP(S) endpoint without embedded credentials or a fragment.") from None


# ---------------------------------------------------------------- the request

def _headers(auth_type: str, credential_ref: str, auth_header: str, url: str) -> dict[str, str]:
    """The probe's headers, under `api.py`'s rules about what may carry a secret."""
    headers = {"Accept": "application/json, application/xml;q=0.8, */*;q=0.5",
               "User-Agent": USER_AGENT}
    if auth_type == "none":
        return headers
    if not credential_ref:
        raise ProbeFailed("Name a worker credential to probe an authenticated endpoint.")
    # credential_for refuses a reference that is not bound to this origin, which
    # is what stops a probe URL from choosing where a worker's secret goes.
    secret = credential_for(credential_ref, url)
    if auth_type == "bearer":
        headers["Authorization"] = "Bearer " + secret
    elif auth_type == "header":
        if not auth_header or any(c in auth_header for c in "\r\n:"):
            raise ProbeFailed("Choose a valid authentication header name.")
        headers[auth_header] = secret
    else:
        raise ProbeFailed("Authentication must be none, bearer or header.")
    return headers


async def _refuse_internal(url: str) -> None:
    """`core.egress`, off the event loop (it resolves), restated as a probe refusal."""
    try:
        await asyncio.to_thread(refuse_internal_egress, url)
    except TerminalError as exc:
        raise ProbeFailed(str(exc)) from None


async def _fetch(url: str, headers: dict[str, str],
                 limit: int = MAX_BYTES) -> tuple[httpx.Response, bytes, bool]:
    """One GET, capped in bytes and time, following at most MAX_REDIRECTS hops.

    `limit` is the byte cap, and the third value says it was reached. The probe
    keeps what it read; `evidence.py` passes one byte more than it will keep, so
    reaching the cap means the page was larger and it refuses the copy.

    BY HAND, NOT `follow_redirects=True`. httpx re-checked nothing on a hop: the
    origin rule ran on the final URL after the request had already been made,
    and the egress guard ran nowhere, so `https://public.example/` answering
    `302 http://169.254.169.254/` was a metadata read returned to the caller.
    Every hop is a new URL and gets the checks the first one got, BEFORE it is
    requested. httpx also stripped only `Authorization` on a cross-origin hop,
    so an `auth_type: header` credential went wherever the endpoint redirected;
    a hop off the starting origin now carries only `ANONYMOUS`.
    """
    start = origin(url)
    async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=False) as client:
        for hop in range(MAX_REDIRECTS + 1):
            await _refuse_internal(url)
            sent = headers if origin(url) == start else {
                k: v for k, v in headers.items() if k in ANONYMOUS}
            async with client.stream("GET", url, headers=sent) as response:
                if response.has_redirect_location:
                    if hop == MAX_REDIRECTS:
                        raise ProbeFailed(
                            f"The endpoint redirected more than {MAX_REDIRECTS} times.")
                    url = urljoin(str(response.url), response.headers["location"])
                    try:
                        origin(url)
                    except TerminalError:
                        raise ProbeFailed(
                            "The endpoint redirected somewhere a probe will not follow.") from None
                    continue
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) >= limit:
                        return response, bytes(body[:limit]), True
                return response, bytes(body), False
    raise AssertionError("unreachable: the loop returns or raises")  # pragma: no cover


# ------------------------------------------------------------ what it is

def detect_wire(content_type: str, body: bytes) -> str:
    """The format, from the bytes first and the header second.

    The header is a claim and the bytes are the fact; APIs that serve JSON as
    `text/plain` are common enough that believing the header loses records.
    """
    head = body[:400].lstrip()
    if head[:1] in (b"{", b"["):
        return "json"
    if head[:5] == b"<?xml" or head[:1] == b"<":
        low = head.lower()
        if b"<html" in low:
            return "html"
        if b"<rss" in low or b"<rdf" in low:
            return "rss"
        if b"<feed" in low:
            return "atom"
        return "xml"
    ct = (content_type or "").lower()
    if "json" in ct:
        return "json"
    if "csv" in ct:
        return "csv"
    if "html" in ct:
        return "html"
    return "unknown"


# --------------------------------------------------------- where the records are

def _candidates(node: Any, path: tuple[str, ...] = (), depth: int = 0,
                out: list | None = None) -> list[tuple[tuple[str, ...], int]]:
    """Every array-of-objects in the document, with its path and length."""
    if out is None:
        out = []
    if depth > 5:
        return out
    if isinstance(node, list):
        if node and isinstance(node[0], dict):
            out.append((path, len(node)))
        return out
    if isinstance(node, dict):
        for key, value in node.items():
            _candidates(value, path + (key,), depth + 1, out)
    return out


def pick_records(payload: Any) -> tuple[list[dict], str, list[str]]:
    """(records, records_path, friction) for a JSON payload.

    `records_path` is in the dot-path dialect `ingest/api.py` reads, not
    JSONPath, because it is going straight into a source configuration. A key
    containing a dot makes that path ambiguous, and rather than emit a path the
    puller would read differently, the probe says so and leaves the path to the
    operator.
    """
    friction: list[str] = []
    if isinstance(payload, list):
        if payload and isinstance(payload[0], dict):
            return payload[:MAX_RECORDS], "$", friction
        return [], "$", ["The response is an array of values rather than of objects."]
    if not isinstance(payload, dict):
        return [], "$", ["The response is a single scalar value, not a list of records."]

    found = _candidates(payload)
    if not found:
        return [payload], "$", ["No repeated record was found: the response looks like one object."]
    found.sort(key=lambda c: (c[1], -len(c[0])), reverse=True)
    segments, _count = found[0]
    if any("." in s for s in segments):
        friction.append(
            "The array of records sits under a key containing a dot "
            f"({'.'.join(segments)}), which a dot path cannot address unambiguously. "
            "Choose records_path yourself.")
        return [], "$", friction
    node = payload
    for part in segments:
        node = node[part]
    if len(found) > 1:
        others = ", ".join(".".join(s) or "$" for s, _ in found[1:4])
        friction.append(f"More than one array of objects was present; also saw {others}.")
    return node[:MAX_RECORDS], ".".join(segments) or "$", friction


# ------------------------------------------------------------- what is in them

def _typeof(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    text = str(value)
    if ISO.match(text):
        return "datetime"
    if re.fullmatch(r"-?\d+", text):
        return "int_str"
    return "str"


def _flatten(record: dict, prefix: str = "", out: dict | None = None, depth: int = 0) -> dict:
    if out is None:
        out = {}
    for key, value in record.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict) and depth < 2:
            out[path] = value
            _flatten(value, path + ".", out, depth + 1)
        else:
            out[path] = value
    return out


def field_tree(records: list[dict]) -> dict[str, dict]:
    """Every leaf path, its dominant type, how often it is present, and examples.

    Two examples per field rather than none: the operator is checking whether
    the probe read the right thing, and a type name alone does not let them.
    """
    total = max(len(records), 1)
    seen: dict[str, dict] = {}
    for record in records:
        if not isinstance(record, dict):
            continue
        for path, value in _flatten(record).items():
            field = seen.setdefault(path, {"types": {}, "present": 0, "values": []})
            kind = _typeof(value)
            field["types"][kind] = field["types"].get(kind, 0) + 1
            field["present"] += 1
            if isinstance(value, (str, int, float, bool)) and len(field["values"]) < 200:
                field["values"].append(value)
    tree = {}
    for path, field in sorted(seen.items())[:MAX_FIELDS]:
        kind = max(field["types"], key=field["types"].get)
        distinct = len({str(v) for v in field["values"]})
        tree[path] = {
            "type": kind,
            "present_pct": round(100 * field["present"] / total),
            "distinct": distinct,
            "unique": distinct == len(field["values"]) and len(field["values"]) > 1,
            "examples": [str(v)[:70] for v in field["values"][:2]],
        }
    return tree


def _looks_like_time(meta: dict) -> bool:
    if meta["type"] == "datetime":
        return True
    if meta["type"] in ("int", "int_str") and meta["examples"]:
        try:
            number = int(float(meta["examples"][0]))
        except ValueError:
            return False
        return 10**8 < number < 4 * 10**9 or 10**11 < number < 4 * 10**12
    return False


def rank_fields(tree: dict[str, dict], records: list[dict]) -> tuple[list[str], list[str]]:
    """(watermark candidates, identity candidates), best first.

    Ranked, not chosen. A field named `updated_at` beats one named `created_at`
    for a watermark because an incremental pull wants the last change, and both
    are offered because plenty of APIs only have the second.
    """
    times, ids = [], []
    for path, meta in tree.items():
        leaf = path.split(".")[-1]
        if meta["type"] == "object":
            continue
        if _looks_like_time(meta) or (DATEY.search(leaf) and meta["type"] in ("str", "int", "int_str")):
            times.append(path)
        if meta["unique"] and meta["present_pct"] > 80 and (
                IDY.search(leaf) or meta["distinct"] == len(records)):
            ids.append(path)
    times.sort(key=lambda p: (0 if re.search(r"(updated|modified|changed)", p, re.I) else
                              1 if re.search(r"(published|created)", p, re.I) else 2, len(p)))
    ids.sort(key=lambda p: (0 if IDY.search(p.split(".")[-1]) else 1, len(p)))
    return times[:4], ids[:4]


# ------------------------------------------------------------- how it paginates

def detect_pagination(response: httpx.Response, payload: Any, url: str) -> dict:
    """The pagination style, from evidence, with the evidence attached.

    Each branch states what was seen. "link_header" because the response carried
    `Link: <...>; rel="next"` is a fact; a model asserting `link_header` because
    the API is on GitHub is not, and the difference is a pull that stops after
    one page.
    """
    if response.links.get("next", {}).get("url"):
        return {"pagination": "link_header",
                "evidence": "the response carried a Link header with rel=next"}
    if isinstance(payload, dict):
        for key, value in payload.items():
            if not isinstance(value, str) or not value:
                continue
            if key.lower() in ("next", "next_url", "nexturl", "next_page", "nextpage"):
                same = False
                try:
                    same = origin(urljoin(str(response.url), value)) == origin(url)
                except Exception:
                    same = False
                return {"pagination": "next_url", "next_path": key,
                        "evidence": f"'{key}' holds a URL" + ("" if same else
                                    " on another origin, which the puller refuses to follow")}
            if key.lower() in ("next_page_token", "nextpagetoken", "page_token", "next_cursor", "cursor"):
                return {"pagination": "page_token", "next_path": key,
                        "evidence": f"'{key}' holds a continuation token"}
    query = dict(parse_qsl(urlsplit(url).query))
    for name in ("page", "page_number", "offset"):
        if name in query:
            return {"pagination": "page", "page_param": name,
                    "evidence": f"the URL already carries a '{name}' parameter"}
    return {"pagination": "none",
            "evidence": "no Link header, continuation field or page parameter was present"}


# ----------------------------------------------------------------- the probe

async def probe(url: str, *, auth_type: str = "none", credential_ref: str = "",
                auth_header: str = "X-API-Key") -> dict:
    """Fetch `url` once and describe it. Raises `ProbeFailed` with what was seen."""
    origin(url)
    if urlsplit(url).query:
        sensitive = {"access_token", "api_key", "apikey", "token", "password", "secret"}
        if any(k.lower() in sensitive for k, _ in parse_qsl(urlsplit(url).query)):
            raise ProbeFailed(
                "Remove the credential from the URL and name a worker credential instead.")

    headers = _headers(auth_type, credential_ref, auth_header, url)
    try:
        response, body, truncated = await _fetch(url, headers)
    except httpx.HTTPError as exc:
        raise ProbeFailed(f"The endpoint could not be reached: {type(exc).__name__}.") from None

    report: dict[str, Any] = {
        "url": str(response.url),
        "status": response.status_code,
        "content_type": (response.headers.get("content-type") or "")[:80],
        "bytes": len(body),
        "truncated": truncated,
        "conditional_get": {"etag": bool(response.headers.get("etag")),
                            "last_modified": bool(response.headers.get("last-modified"))},
        "friction": [],
    }
    if response.status_code >= 400:
        report["kind"] = "error"
        report["friction"].append(
            f"The endpoint answered {response.status_code}. "
            + ("Authentication may be required." if response.status_code in (401, 403)
               else "Check the path and parameters."))
        report["body_head"] = body[:300].decode("utf-8", "replace")
        return report

    wire = detect_wire(report["content_type"], body)
    report["wire"] = wire
    if not report["conditional_get"]["etag"] and not report["conditional_get"]["last_modified"]:
        report["friction"].append(
            "No ETag or Last-Modified: a conditional GET cannot cheapen re-reads.")
    if truncated:
        report["friction"].append(
            f"Only the first {MAX_BYTES // 1000}kB were read; the shape below is from that much.")

    if wire != "json":
        report["kind"] = "unsupported"
        report["friction"].append(
            f"The response is {wire}, and incremental API ingestion reads JSON. "
            "A feed or document source is the right shape for this URL.")
        report["body_head"] = body[:300].decode("utf-8", "replace")
        return report

    try:
        payload = json.loads(body)
    except ValueError:
        report["kind"] = "unsupported"
        report["friction"].append("The body starts like JSON and does not parse as JSON.")
        report["body_head"] = body[:300].decode("utf-8", "replace")
        return report

    if isinstance(payload, dict) and (payload.get("openapi") or payload.get("swagger")):
        report["kind"] = "openapi"
        operations = await _operations(url, credential_ref)
        report["operations"] = operations["operations"]
        report["friction"].extend(operations["friction"])
        return report

    records, records_path, friction = pick_records(payload)
    report["friction"].extend(friction)
    report["kind"] = "records"
    tree = field_tree([r for r in records if isinstance(r, dict)])
    times, ids = rank_fields(tree, records)
    report["observed"] = {
        "records_path": records_path,
        "record_count": len(records),
        "fields": tree,
        "sample": records[0] if records else None,
        **detect_pagination(response, payload, url),
    }
    report["inferred"] = {
        "watermark_candidates": times,
        "watermark_field": times[0] if times else "",
        "watermark_type": ("timestamp" if times and tree[times[0]]["type"] == "datetime"
                           else "number" if times else "none"),
        "id_candidates": ids,
        "id_path": ids[0] if ids else "",
    }
    if not times:
        report["friction"].append(
            "No field looks like a change time, so this source cannot pull incrementally "
            "on a watermark without one being named.")
    if not ids:
        report["friction"].append(
            "No field is unique across the records read, so deduplication needs an id_path "
            "that this page could not confirm.")
    if times:
        report["friction"].append(
            "The request parameter that filters by the watermark cannot be seen in a "
            "response — it comes from the API's documentation. watermark_param is not "
            "inferred here.")
    arrays = [p for p, m in tree.items() if m["type"] == "array"]
    if arrays:
        report["friction"].append(
            f"Array-valued fields need a decision before mapping: {', '.join(arrays[:3])}.")
    return report


async def _operations(url: str, credential_ref: str) -> dict:
    """The document's operations, through the OpenAPI provider this runtime already has.

    A second parser here would be a second answer to "what does this document
    offer", and the one in `agentic/tools/openapi.py` is the one that has to
    stay right because agents bind to what it returns.
    """
    from ..agentic.contracts import ToolServer
    from ..agentic.tools import OpenApiProvider

    server = ToolServer(name="probe", kind="openapi", url=url,
                        credential_ref=credential_ref or None)
    try:
        tools = await OpenApiProvider().list_tools(server)
    except Exception as exc:
        return {"friction": [f"The OpenAPI document could not be read: {type(exc).__name__}."],
                "operations": []}
    return {
        "operations": [{"name": t.name, "description": (t.description or "")[:200]}
                       for t in tools[:40]],
        "friction": [
            "This URL is an OpenAPI document, not a data endpoint. Its operations are "
            "listed; probe the one that returns the records to get a record path.",
        ],
    }
