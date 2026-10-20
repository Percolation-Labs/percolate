#!/usr/bin/env python3
"""Tool binding: register a server, discover its tools, call one.

    python3 binder.py apply percolate.yaml     # register + discover
    python3 binder.py tools p8-workflow        # what the discovery found
    python3 binder.py call p8-query query '{"query": "SCHEMA"}'
    python3 binder.py sql percolate.yaml       # emit the seed migration

This is the reference for `brief.md` §5.2, and the claim it exists to make
checkable is a narrow one: **a tool server is a url and a name, and everything
else about it is discovered.** Nowhere in this file is there a branch on which
service is being bound. Grep it for a domain noun and there is nothing to find
-- `workflow`, `query`, `start_workflow` appear only in the YAML a user wrote.

The three stages, kept separate on purpose:

  register   an upsert into agentic.tool_servers. Name, kind, url, flags.
             No network. This is what a migration does, and it is all a
             `docker compose up` needs to produce a working system.
  discover   fetch the OpenAPI document, or connect and call `tools/list`,
             and adapt whatever comes back into ONE canonical tool shape.
             Cached onto the row; re-run whenever the upstream changes.
  invoke     read a canonical tool, make the call. By this point nothing
             knows or asks whether the tool came from MCP or OpenAPI --
             which is the actual test of whether the adapter did its job.

The canonical shape, which is MCP's with one addition:

    {"name": ..., "description": ..., "input_schema": {...},
     "invoke": {"transport": "mcp",     "tool": "query"}
            or {"transport": "openapi", "method": "POST",
                "path": "/rpc/start_workflow", "params": {"p_name": "body"}}}

`invoke` is the addition, and it is why the call stage can be kind-blind: MCP
carries its invocation target implicitly (the tool name IS the target), an
OpenAPI operation does not, so the adapter writes one down for both.

Standard library plus PyYAML.
"""
import argparse
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml

TIMEOUT = 30


# ==============================================================
# HTTP, and the two failure kinds this collection keeps apart
# ==============================================================

class ToolError(Exception):
    """The server responded and the call failed (brief §5.2, kind 1)."""
    kind = "tool_error"


class DispatchError(Exception):
    """The server could not be reached at all (brief §5.2, kind 2)."""
    kind = "dispatch_error"


def http(method, url, headers=None, body=None):
    req = urllib.request.Request(
        url, method=method, data=None if body is None else json.dumps(body).encode(),
        headers={**({"Content-Type": "application/json"} if body is not None else {}),
                 "Accept": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
            if not raw:
                return None
            try:
                return json.loads(raw)
            except ValueError:
                return {"_raw": raw.decode(errors="replace")}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:2000]
        raise ToolError(f"{method} {url} -> {e.code}: {detail}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise DispatchError(f"{method} {url}: {e}") from None


def resolve_credential(ref):
    """`env:NAME` -> the value. Never a literal secret in the row (§5.2).

    The only scheme implemented, and the collection has no secrets manager
    yet, so `vault://` is recognised well enough to fail with the right
    sentence rather than silently binding an unauthenticated server -- which
    is the exact failure `credential_ref`-in-the-view was added to prevent.
    """
    if not ref:
        return None
    scheme, _, rest = ref.partition(":")
    if scheme == "env":
        v = os.environ.get(rest)
        if not v:
            raise DispatchError(
                f"credential_ref {ref!r} names an environment variable that is "
                f"not set. Binding would succeed and every tool the caller's "
                f"role cannot see anonymously would silently be missing.")
        return v
    raise DispatchError(f"credential_ref scheme {scheme!r} is not implemented")


def auth_headers(server, caller_token=None):
    """Headers for one request, and the one place two identities meet.

    `credential_ref` is the identity a server is REGISTERED with, and it is a
    discovery-time concern: the tool list has to be fetched as somebody who
    can see the surface the agent is meant to have, or the sync silently
    returns the anonymous subset (which is how this sample first bound the
    workflow server and lost start_workflow, runs_api and tasks_api without
    an error anywhere).

    A CALL is different: it must run as the person talking to the agent, so
    the caller's token wins whenever there is one. A tool server that called
    upstream as itself would hand every user the same, maximal, result set --
    the failure brief.md §11.1 is about. The two identities differing is
    normal, and its visible consequence is that an agent can be offered a tool
    its user may not execute; that returns a tool_error, which is an
    observation the model handles like any other.
    """
    h = dict(server.get("default_headers") or {})
    tok = caller_token or resolve_credential(server.get("credential_ref"))
    if tok:
        h["Authorization"] = f"Bearer {tok}"
    return h


# ==============================================================
# Discovery -- OpenAPI
# ==============================================================

def _deref(doc, node):
    """Follow a local $ref. Swagger 2.0 puts shared parameters in
    #/parameters; 3.x puts them in #/components/parameters. Both appear in the
    wild and PostgREST 12 uses the first, so an adapter that handles only 3.x
    cannot bind the REST surface this collection itself runs."""
    seen = 0
    while isinstance(node, dict) and "$ref" in node:
        seen += 1
        if seen > 10:
            raise ToolError("$ref chain too deep")
        ref = node["$ref"]
        if not ref.startswith("#/"):
            raise ToolError(f"remote $ref not supported: {ref}")
        cur = doc
        for part in ref[2:].split("/"):
            part = part.replace("~1", "/").replace("~0", "~")
            cur = cur[part]
        node = cur
    return node


def _openapi_type(p):
    """Swagger 2.0 puts type/format on the parameter; 3.x nests a schema."""
    if "schema" in p and isinstance(p["schema"], dict):
        s = dict(p["schema"])
        s.pop("$ref", None)
        return s or {"type": "string"}
    out = {k: v for k, v in p.items()
           if k in ("type", "enum", "items", "default", "format")}
    return out or {"type": "string"}


def adapt_openapi(doc):
    """Every operation in the document -> canonical tools.

    Mechanical, with no per-service knowledge anywhere in it:

      name         operationId, else method_path -- because operationId is
                   OPTIONAL in OpenAPI and PostgREST emits none at all, so a
                   binder that requires it binds nothing.
      description  summary and description joined. PostgREST derives both from
                   COMMENT ON, first line into summary -- so how usable a
                   bound tool is depends on the database, not on this file.
      input_schema path, query and body parameters merged into one
                   object, with each parameter's own `in` recorded so the call
                   stage can split them apart again. Header parameters are
                   left out -- see the note at the skip below.
      invoke       method and path template, and nothing else. The base url
                   is deliberately NOT stored per tool: it belongs to the
                   server row, so a service that moves is one url edited in
                   one place rather than a re-discovery to correct a base that
                   had been copied into all 85 of its tools.

    The base url used is the one the row was registered with -- never the
    host/basePath (2.0) or servers (3.x) the document claims. Those routinely
    describe the service as it sees itself from behind a proxy, while the
    registered address is one that demonstrably just worked.
    """
    tools = []
    for path, item in sorted((doc.get("paths") or {}).items()):
        item = _deref(doc, item)
        for method, op in sorted(item.items()):
            if method not in ("get", "post", "put", "patch", "delete"):
                continue
            props, required, where = {}, [], {}

            for p in (op.get("parameters") or []) + (item.get("parameters") or []):
                p = _deref(doc, p)
                loc = p.get("in")
                if loc == "body":                       # 2.0 body parameter
                    schema = _deref(doc, p.get("schema") or {})
                    for k, v in (schema.get("properties") or {}).items():
                        props[k] = v
                        where[k] = "body"
                    required += [r for r in (schema.get("required") or [])]
                    continue
                # Headers are transport, not arguments. Including them --
                # which the first version did, faithfully, because the
                # document lists them as parameters -- put `Prefer`, `Range`
                # and `Range-Unit` into the input schema of all 85 PostgREST
                # tools, so every operation advertised three arguments about
                # HTTP framing and a model had to ignore them on every call.
                # The header a service genuinely needs is a property of the
                # SERVER, not of one operation, and it is already handled one
                # layer up by credential_ref and default_headers.
                if loc not in ("path", "query"):
                    continue
                name = p.get("name")
                if not name:
                    continue
                props[name] = {**_openapi_type(p),
                               **({"description": p["description"]}
                                  if p.get("description") else {})}
                where[name] = loc
                if p.get("required"):
                    required.append(name)

            body = _deref(doc, op.get("requestBody") or {})   # 3.x request body
            schema = _deref(doc, ((body.get("content") or {})
                                  .get("application/json") or {}).get("schema") or {})
            for k, v in (schema.get("properties") or {}).items():
                props[k] = v
                where[k] = "body"
            required += list(schema.get("required") or [])

            slug = re.sub(r"[^a-zA-Z0-9]+", "_", path).strip("_")
            if not op.get("operationId") and not slug:
                # `GET /` with no operationId can only be named `get_`, which
                # is not a tool name, and on PostgREST that path is the
                # OpenAPI document itself -- an operation the binder used to
                # bind as a tool that hands the model the tool list it is
                # already holding. Named by the document or skipped; there is
                # no third option that produces something callable.
                continue
            name = op.get("operationId") or "%s_%s" % (method, slug)
            desc = "\n\n".join(x for x in (op.get("summary"),
                                           op.get("description")) if x)
            tools.append({
                "name": name,
                "description": desc,
                "input_schema": {"type": "object", "properties": props,
                                 "required": sorted(set(required))},
                "invoke": {"transport": "openapi", "method": method.upper(),
                           "path": path, "params": where},
            })
    return tools


def discover_openapi(server):
    base = server["url"].rstrip("/")
    doc = http("GET", base + "/", headers=auth_headers(server))
    return adapt_openapi(doc)


# ==============================================================
# Discovery -- MCP
# ==============================================================

def mcp_rpc(server, method, params=None, rid=1, caller_token=None):
    body = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        body["params"] = params
    r = http("POST", server["url"], headers={
        "Accept": "application/json, text/event-stream",
        **auth_headers(server, caller_token)}, body=body)
    if isinstance(r, dict) and r.get("error"):
        raise ToolError("%s: %s" % (method, r["error"].get("message")))
    return (r or {}).get("result") or {}


def discover_mcp(server):
    """initialize, then tools/list. MCP already IS the canonical shape, so
    this adapter only renames `inputSchema` and writes down an invoke block --
    which is the point of §5.2 choosing MCP's shape as the canonical one."""
    mcp_rpc(server, "initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "p8-binder", "version": "0.1.0"}})
    listed = mcp_rpc(server, "tools/list", {}, rid=2)
    return [{
        "name": t["name"],
        "description": t.get("description") or t.get("title") or "",
        "input_schema": t.get("inputSchema") or {"type": "object", "properties": {}},
        "invoke": {"transport": "mcp", "tool": t["name"]},
    } for t in listed.get("tools", [])]


DISCOVER = {"openapi": discover_openapi, "mcp": discover_mcp}


# ==============================================================
# Invocation -- one code path, both kinds
# ==============================================================

def invoke(server, tool, arguments, caller_token=None):
    """Call a canonical tool. Note what this function does NOT receive: the
    server's kind. It reads `invoke.transport` off the tool the discovery
    stage produced, which is the whole claim of §5.2 reduced to one dispatch."""
    inv = tool["invoke"]

    if inv["transport"] == "mcp":
        res = mcp_rpc(server, "tools/call",
                      {"name": inv["tool"], "arguments": arguments}, rid=3,
                      caller_token=caller_token)
        if res.get("isError"):
            raise ToolError(json.dumps(res.get("content")))
        return res.get("structuredContent", res.get("content"))

    where = inv.get("params") or {}
    path, query, body = inv["path"], {}, {}
    headers = dict(auth_headers(server, caller_token))
    for k, v in (arguments or {}).items():
        loc = where.get(k, "body")
        if loc == "path":
            path = path.replace("{%s}" % k, urllib.parse.quote(str(v), safe=""))
        elif loc == "query":
            query[k] = v if isinstance(v, str) else json.dumps(v)
        elif loc == "header":
            headers[k] = str(v)
        else:
            body[k] = v
    url = server["url"].rstrip("/") + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    return http(inv["method"], url, headers=headers,
                body=body if inv["method"] != "GET" else None)


# ==============================================================
# The database side -- everything through the documented surface
# ==============================================================

class Percolate:
    """PostgREST, `agentic` profile. This registers tool servers by calling
    `agentic.upsert_tool_server` -- the same RPC any other client would use,
    not a direct table write, so the permission check and the RLS story are
    the ones the schema actually ships."""

    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.token = token

    def _h(self, schema):
        return {"Accept-Profile": schema, "Content-Profile": schema,
                **({"Authorization": f"Bearer {self.token}"} if self.token else {})}

    def rpc(self, schema, fn, payload):
        return http("POST", f"{self.base}/rpc/{fn}", headers=self._h(schema),
                    body=payload)

    def server(self, name):
        rows = http("GET", "%s/tool_servers_api?name=eq.%s" % (
            self.base, urllib.parse.quote(name)), headers=self._h("agentic"))
        if not rows:
            raise ToolError(
                f"no tool server named {name!r}. Register it first: "
                f"binder.py apply <yaml>")
        return rows[0]


# ==============================================================
# The declarative document
# ==============================================================

def load(path):
    doc = yaml.safe_load(pathlib.Path(path).read_text()) or {}
    return (doc.get("tool_servers") or [], doc.get("skills") or [],
            doc.get("agents") or [])


def cmd_apply(a):
    p8 = Percolate(a.postgrest, a.token)
    servers, skills, agents = load(a.file)

    for s in servers:
        p8.rpc("agentic", "upsert_tool_server", {"p_spec": s})
        print(f"registered  {s['name']:<16} {s['kind']:<8} {s['url']}")
        if a.no_discover:
            continue
        try:
            tools = DISCOVER[s["kind"]](s)
        except (ToolError, DispatchError) as e:
            # Registration stands, discovery is retried later: an upstream
            # that is down at migration time must not lose the row that says
            # it exists. This is why the two stages are separate calls.
            print(f"  discovery deferred ({e.__class__.kind}): {e}")
            continue
        p8.rpc("agentic", "upsert_tool_server",
               {"p_spec": {**s, "cached_tools": tools}})
        print(f"  discovered {len(tools)} tools: "
              + ", ".join(t["name"] for t in tools[:6])
              + (" ..." if len(tools) > 6 else ""))

    for sk in skills:
        p8.rpc("agentic", "upsert_skill", {"p_spec": sk})
        print(f"skill       {sk['name']:<16} {len(sk.get('content',''))} chars")

    for ag in agents:
        p8.rpc("agentic", "upsert_agent", {"p_spec": ag})
        bound = ", ".join("%s:%s" % (t["server"], len(t.get("tools") or []) or "*")
                          for t in ag.get("tools") or [])
        print(f"agent       {ag['name']:<16} tools[{bound}]")

    # The check the whole design turns on: an agent may only name a server
    # that exists, and a tool that discovery actually found. Catching it here
    # is the difference between a broken agent and a broken deploy.
    by_name = {s["name"]: s for s in servers}
    for ag in agents:
        for binding in ag.get("tools") or []:
            sname = binding["server"]
            if sname not in by_name:
                print(f"  WARNING {ag['name']} binds unregistered server {sname!r}")
                continue
            try:
                have = {t["name"] for t in p8.server(sname)["cached_tools"]}
            except (ToolError, DispatchError):
                continue
            if not have:
                continue
            for want in binding.get("tools") or []:
                if want not in have:
                    print(f"  WARNING {ag['name']} binds {sname}.{want!r}, "
                          f"which that server does not expose")


def cmd_tools(a):
    p8 = Percolate(a.postgrest, a.token)
    s = p8.server(a.server)
    tools = s["cached_tools"]
    print(f"{s['name']}  ({s['kind']})  {s['url']}  synced={s['synced_at']}")
    for t in tools:
        head = (t.get("description") or "").strip().splitlines()
        args = ", ".join(sorted((t.get("input_schema") or {}).get("properties") or {}))
        print(f"\n  {t['name']}({args})")
        print(f"    {head[0] if head else '-- no description --'}")


def cmd_call(a):
    p8 = Percolate(a.postgrest, a.token)
    s = p8.server(a.server)
    tool = next((t for t in s["cached_tools"] if t["name"] == a.tool), None)
    if tool is None:
        sys.exit(f"{a.server} exposes no tool named {a.tool!r} "
                 f"(run: binder.py tools {a.server})")
    try:
        # The caller's token, forwarded -- see auth_headers on why a call uses
        # a different identity from the one the server was registered with.
        print(json.dumps(invoke(s, tool, json.loads(a.arguments), a.token),
                         indent=2))
    except (ToolError, DispatchError) as e:
        print(json.dumps({"is_error": True, "error_kind": e.__class__.kind,
                          "detail": str(e)}, indent=2))
        sys.exit(1)


def cmd_sql(a):
    """The same document as a migration -- registration only, no discovery.

    Generated rather than hand-written for the reason `build-sql.py` gives:
    the YAML is what gets reviewed, and a hand-copied SQL copy is a second
    copy to drift.
    """
    servers, skills, agents = load(a.file)
    src = pathlib.Path(a.file).name
    out = [SEED_HEADER % src, "set role app_owner;\n", SEED_GUARD]
    for s in servers:
        out.append("    perform agentic.upsert_tool_server($p8$%s$p8$::jsonb);\n"
                   % json.dumps(s, indent=4))
    # Skills before agents, and not for tidiness: upsert_agent refuses a
    # composed skill that does not exist yet (plugins.md §5.1), so an agent
    # emitted first would fail at initdb against its own migration.
    for sk in skills:
        out.append("    perform agentic.upsert_skill($p8$%s$p8$::jsonb);\n"
                   % json.dumps(sk, indent=4))
    for ag in agents:
        out.append("    perform agentic.upsert_agent($p8$%s$p8$::jsonb);\n"
                   % json.dumps(ag, indent=4))
    out.append("end $$;\n\nreset role;\n")
    body = "\n".join(out)
    if a.out:
        path = pathlib.Path(a.out)
        if a.check:
            if not path.exists() or path.read_text() != body:
                sys.exit(f"STALE: {a.out} does not match {a.file} -- "
                         f"run: binder.py sql {a.file} -o {a.out}")
            print(f"{a.out} is current")
            return
        path.write_text(body)
        print(f"wrote {a.out}")
    else:
        sys.stdout.write(body)


SEED_GUARD = """\
do $$
begin
    -- The skew check, and why it warns instead of failing.
    --
    -- This file runs at initdb against whatever schema the DATABASE IMAGE
    -- carries, and the image is built from specs/ at publish time -- so a
    -- stack pulled before this sample landed has no `default_headers` column
    -- and no `may_author`, and every statement below would abort container
    -- startup. Bricking the stack is a worse answer than not having the
    -- sample: the other four subsystems are fine.
    --
    -- So it says so, loudly, and skips. `surface.sql` is what turns the
    -- absence back into a failure at the point where a failure is useful --
    -- the same division of labour the collection already uses for the
    -- compiled parser (`workflow.compiler_capabilities()`).
    if to_regprocedure('agentic.may_author(text,regclass)') is null
       or to_regclass('agentic.skills') is null
       or not exists (select 1 from pg_catalog.pg_attribute
                       where attrelid = 'agentic.tool_servers'::regclass
                         and attname = 'default_headers' and not attisdropped) then
        raise warning
            'skipping the sample agent: this database image predates it '
            '(agentic.may_author, agentic.skills or tool_servers.default_headers '
            'is missing). Everything else installed normally. To get the sample, '
            'rebuild the image from the current specs: dev/build-image.sh';
        return;
    end if;

"""

SEED_HEADER = """\
-- Sample: the Percolate agent and the two tool servers it binds.
--
-- GENERATED from specs/agentic/reference/%s by binder.py. Do not edit.
--
-- Registration only. `cached_tools` stays empty here and is filled by the
-- discovery stage (`binder.py apply`, or the scheduled re-sync), because
-- discovery is an HTTP fetch and this file runs at initdb -- before the
-- servers it names are listening, and inside a database that deliberately
-- has no HTTP client (specs/README.md: the database never blocks on HTTP).
--
-- An agent bound to a server whose tools have not been discovered yet is not
-- broken, it is unsynced: the row says which server and which tool names, and
-- the descriptions arrive when something can reach the upstream.
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--postgrest", default=os.environ.get(
        "P8_POSTGREST", "http://localhost:3000"))
    ap.add_argument("--token", default=os.environ.get("P8_TOKEN"),
                    help="JWT for the identity doing this (needs agents:update)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("apply", help="register servers and agents, then discover")
    s.add_argument("file")
    s.add_argument("--no-discover", action="store_true")
    s.set_defaults(fn=cmd_apply)

    s = sub.add_parser("tools", help="show a server's discovered tools")
    s.add_argument("server")
    s.set_defaults(fn=cmd_tools)

    s = sub.add_parser("call", help="invoke one discovered tool")
    s.add_argument("server")
    s.add_argument("tool")
    s.add_argument("arguments", nargs="?", default="{}")
    s.set_defaults(fn=cmd_call)

    s = sub.add_parser("sql", help="emit the registration migration")
    s.add_argument("file")
    s.add_argument("-o", "--out")
    s.add_argument("--check", action="store_true")
    s.set_defaults(fn=cmd_sql)

    a = ap.parse_args()
    try:
        a.fn(a)
    except DispatchError as e:
        sys.exit(f"unreachable: {e}")
    except ToolError as e:
        sys.exit(f"failed: {e}")


if __name__ == "__main__":
    main()
