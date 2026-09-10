"""OpenAPI provider — an adapter onto the MCP shape, not a second mechanism.

``brief.md`` §5.2: "An OpenAPI binding is an *adapter* ... it turns each selected
OpenAPI operation into that same canonical shape (operation →
name/description/schema, the endpoint URL + HTTP method → the invocation target)
before handing anything to pydantic-ai."

The services this actually binds to are CRUD — PostgREST over some schema, or a
small OpenAPI service in front of one — which is exactly why this file contains
no per-service knowledge of any kind. It reads a document and produces tools; if
a service ever needs a hand-written adapter here, that service is not the shape
this system binds to.

Swagger 2.0 *and* OpenAPI 3.x are both handled, and that is not gold-plating:
PostgREST 12 — this collection's own REST surface, and the most likely first
tool server anyone registers — emits 2.0.

The test for whether this module stays honest: nothing outside it may branch on
``kind == "openapi"``.
"""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import urljoin

import httpx

from ..contracts import (
    CanonicalTool,
    InvocationTarget,
    ToolInvocation,
    ToolResult,
    ToolServer,
)
from .auth import outbound_headers

HTTP_METHODS = ("get", "post", "put", "patch", "delete")

RESERVED_HEADERS = ("authorization", "cookie", "proxy-authorization")
"""Headers a tool argument may never set.

An OpenAPI document can declare a header *parameter*, which becomes an ordinary
input-schema property — so without this, a document could hand the model the
ability to set `Authorization` on the runtime's own outbound call, overriding
the credential the `tool_servers` row resolved. Confirmed against a real
service: a model-supplied `Authorization` reached it and displaced ours. The
ambient-context headers are reserved for the same reason: `X-P8-Tenant` is an
assertion the runtime makes, not one a tool call gets to forge.
"""


def _is_reserved(name: str) -> bool:
    lowered = name.lower()
    return lowered in RESERVED_HEADERS or lowered.startswith("x-p8-")
_SLUG = re.compile(r"[^a-zA-Z0-9]+")


def _resolve(doc: dict[str, Any], node: Any) -> Any:
    """Follow a local ``$ref`` one hop. Documents that ref remotely are refused
    rather than half-followed: a partially resolved schema is worse than none."""
    if isinstance(node, dict) and "$ref" in node:
        ref = node["$ref"]
        if not ref.startswith("#/"):
            raise ValueError(f"remote $ref not supported: {ref}")
        target: Any = doc
        for part in ref[2:].split("/"):
            target = target[part]
        return _resolve(doc, target)
    return node


def tool_name(path: str, method: str, operation: dict[str, Any]) -> str:
    """``operationId`` when present, else ``method_path``.

    The fallback is not cosmetic: ``operationId`` is optional in OpenAPI and
    PostgREST omits it entirely, so a spec that insisted on it would refuse to
    bind this collection's own REST surface.
    """
    if operation.get("operationId"):
        return _SLUG.sub("_", operation["operationId"]).strip("_")
    return _SLUG.sub("_", f"{method}_{path}").strip("_")


def operation_to_tool(
    doc: dict[str, Any], server: ToolServer, path: str, method: str, operation: dict[str, Any]
) -> CanonicalTool:
    """Normalise one operation into a ``CanonicalTool``.

    The LLM is shown *one flat object*, because that is what a tool call is —
    path, query and body parameters merged. ``param_in`` records where each
    property came from so ``invoke`` can rebuild a real request without parsing
    the document again at call time.
    """
    properties: dict[str, Any] = {}
    required: list[str] = []
    param_in: dict[str, str] = {}

    for raw in operation.get("parameters", []):
        param = _resolve(doc, raw)
        location = param.get("in")
        if location == "body":  # Swagger 2.0
            schema = _resolve(doc, param.get("schema", {}))
            for name, prop in (schema.get("properties") or {}).items():
                properties[name] = _resolve(doc, prop)
                param_in[name] = "body"
            required.extend(schema.get("required", []))
        elif location in ("query", "path", "header"):
            name = param["name"]
            if location == "header" and _is_reserved(name):
                # Not offered to the model at all: refusing at call time is the
                # backstop, not the control.
                continue
            properties[name] = {
                "type": param.get("type", "string"),
                "description": param.get("description", ""),
            }
            param_in[name] = location
            if param.get("required"):
                required.append(name)

    body = operation.get("requestBody")  # OpenAPI 3.x
    if body:
        schema = _resolve(doc, _resolve(doc, body).get("content", {}).get(
            "application/json", {}).get("schema", {}))
        for name, prop in (schema.get("properties") or {}).items():
            properties[name] = _resolve(doc, prop)
            param_in[name] = "body"
        required.extend(schema.get("required", []))

    return CanonicalTool(
        name=tool_name(path, method, operation),
        description=(
            operation.get("summary")
            or operation.get("description")
            or " ".join(operation.get("tags", []))
            or f"{method.upper()} {path}"
        ),
        input_schema={
            "type": "object",
            "properties": properties,
            "required": sorted(set(required)),
        },
        server_id=server.id,
        server_name=server.name,
        kind="openapi",
        target=InvocationTarget(
            tool_name=tool_name(path, method, operation),
            method=method.upper(),
            path=path,
            param_in=param_in,
        ),
    )


class OpenApiProvider:
    """Fetches a document once at registration; calls operations over HTTP."""

    kind = "openapi"

    async def list_tools(self, server: ToolServer) -> list[CanonicalTool]:
        """GET the document at ``server.url`` and map every operation.

        Fetched *with credentials*, because a role-filtered document is the
        normal case — PostgREST shows an anonymous caller a different (usually
        empty) surface than an authenticated one, so an unauthenticated sync
        would cache a truthful-looking but wrong tool list.

        No per-agent allowlist is applied here: the cache is a faithful picture
        of the upstream, and narrowing happens at resolution time.

        OPEN (``brief.md`` §9): what happens when the document later changes out
        from under a cached binding. Leaning loud — compare on re-sync, refuse to
        resolve a drifted tool — but not settled, and not silently settled here.
        """
        headers = await outbound_headers(server)
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get(server.url, headers=headers)
            response.raise_for_status()
            doc = response.json()

        tools: list[CanonicalTool] = []
        for path, item in (doc.get("paths") or {}).items():
            for method in HTTP_METHODS:
                if method in item:
                    tools.append(operation_to_tool(doc, server, path, method, item[method]))
        return tools

    async def invoke(
        self,
        server: ToolServer,
        tool: CanonicalTool,
        call: ToolInvocation,
        headers: dict[str, str] | None = None,
    ) -> ToolResult:
        """Rebuild the request from ``target`` + arguments, and classify failure.

        Two error kinds, kept apart because they are different facts
        (``brief.md`` §5.2): a non-2xx means the service answered and the call
        failed (``tool_error``); a timeout or refused connection means it was
        never reached (``dispatch_error``).

        No retry loop. The only automatic retry the spec allows comes from
        ``workflow-engine``'s ``http_call``, reused rather than reinvented — a
        loop here would be the second policy the spec explicitly refuses.
        """
        target = tool.target
        assert target is not None and target.path and target.method

        path = target.path
        query: dict[str, Any] = {}
        body: dict[str, Any] = {}
        url = urljoin(_base(server.url), path.lstrip("/"))
        try:
            outbound = await outbound_headers(server, headers, url=url)
        except (LookupError, NotImplementedError) as exc:
            # A credential this runtime cannot resolve is a tool it cannot
            # reach, which §5.2 already has a name for. Letting it raise instead
            # killed the whole run through pydantic-ai's retry — and an
            # unresolvable credential is the single most likely failure in a
            # fresh deployment.
            return ToolResult(
                call_id=call.call_id,
                tool_name=tool.name,
                content=f"{type(exc).__name__}: {exc}",
                is_error=True,
                error_kind="dispatch_error",
            )
        outbound["Accept"] = "application/json"

        for name, value in call.arguments.items():
            where = target.param_in.get(name, "query")
            if where == "path":
                path = path.replace("{" + name + "}", str(value))
            elif where == "header":
                if _is_reserved(name):
                    return ToolResult(
                        call_id=call.call_id,
                        tool_name=tool.name,
                        content=f"refusing to set reserved header {name!r}",
                        is_error=True,
                        error_kind="dispatch_error",
                    )
                outbound[name] = str(value)
            elif where == "body":
                body[name] = value
            else:
                query[name] = value

        url = urljoin(_base(server.url), path.lstrip("/"))
        from .auth import origin
        if origin(url) != origin(server.url):
            return ToolResult(call_id=call.call_id, tool_name=tool.name,
                              content="tool target changed origin", is_error=True,
                              error_kind="dispatch_error")
        try:
            async with httpx.AsyncClient(timeout=30, follow_redirects=False) as client:
                response = await client.request(
                    target.method, url, params=query or None, json=body or None,
                    headers=outbound,
                )
        except httpx.RequestError as exc:
            return ToolResult(
                call_id=call.call_id,
                tool_name=tool.name,
                content=f"{type(exc).__name__}: {exc}",
                is_error=True,
                error_kind="dispatch_error",
            )

        content: Any
        try:
            content = response.json()
        except ValueError:
            content = response.text

        return ToolResult(
            call_id=call.call_id,
            tool_name=tool.name,
            content=content,
            is_error=response.is_error,
            error_kind="tool_error" if response.is_error else None,
        )


def _base(url: str) -> str:
    """The base URL is where the document was fetched from, not what it claims.

    Swagger 2.0's `host`/`basePath` and OpenAPI 3's `servers` routinely lie when
    a service sits behind a proxy — and we already hold an address that
    demonstrably works, so preferring the document's would be trading a fact for
    a claim.
    """
    return url if url.endswith("/") else url.rsplit("/", 1)[0] + "/"


def _auth_headers(credential: str | None) -> dict[str, str]:
    return {"Authorization": f"Bearer {credential}"} if credential else {}
