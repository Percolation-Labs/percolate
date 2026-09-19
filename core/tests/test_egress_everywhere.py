"""No signed-in caller can point an outbound fetch back at this network.

The worker was guarded (REM-91 item 6, `test_worker_egress.py`) and the guard
lived in `worker/http.py`, called from one line. Two other processes fetch a URL
a caller chose and neither called it: `POST /probe` on the Content Server GETs
any http(s) URL for any signed-in caller, follows redirects, and returns what it
read; an API source's `url` is pulled by `ingest/api.py`. Both sit on the same
network as Postgres, MinIO and PostgREST, and `core.credentials.origin` checks a
URL's scheme and userinfo, never the address its host resolves to.

These drive the two public entry points -- `probe()` and `api_pull()` -- rather
than the guard, so they say what a caller can reach, and so they fail on a tree
where the guard exists but nobody calls it. Every redirect hop is a new URL and
is checked as one.

No network except the loopback case, which listens on 127.0.0.1 and asserts
that the listener was never reached. `getaddrinfo` is patched as in
`test_worker_egress.py`; the transport is `httpx.MockTransport`.
"""
import asyncio
import ipaddress
import json
import os
import socket
import threading
import unittest
from contextlib import asynccontextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import httpx

from percolate_core.content import probe as probe_module
from percolate_core.content.probe import ProbeFailed, probe
from percolate_core.core import TerminalError
from percolate_core.core.egress import EgressRefused, refuse_internal_egress
from percolate_core.ingest import api as api_module

PUBLIC = "93.184.216.34"
RECORDS = [{"id": 1, "updated_at": "2026-09-01T10:00:00Z"},
           {"id": 2, "updated_at": "2026-09-02T10:00:00Z"}]


def resolving(table: dict[str, str]):
    """getaddrinfo answering from `table`; an IP literal answers as itself."""
    def fake(host, port, *args, **kwargs):
        if host in table:
            return [(2, 1, 6, "", (table[host], port))]
        try:
            ipaddress.ip_address(host.strip("[]"))
        except ValueError:
            raise socket.gaierror("not in the test's table") from None
        return [(2, 1, 6, "", (host.strip("[]"), port))]
    return patch("socket.getaddrinfo", side_effect=fake)


class Upstream:
    """A mock network: what answers where, and every request that was sent."""

    def __init__(self):
        self.sent: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.sent.append(request)
        path = request.url.path
        if path.startswith("/to/"):
            # /to/<scheme>/<host>/<rest>: a redirect to wherever the path says.
            _, _, scheme, host, *rest = path.split("/")
            return httpx.Response(302, headers={"Location": f"{scheme}://{host}/{'/'.join(rest)}"},
                                  request=request)
        return httpx.Response(200, json=RECORDS, request=request)

    def patch(self):
        real = httpx.AsyncClient
        return patch.object(probe_module.httpx, "AsyncClient",
                            lambda *a, **kw: real(*a, transport=httpx.MockTransport(self), **kw))

    def hosts(self) -> list[str]:
        return [r.url.host for r in self.sent]


def run_probe(url: str, **kw):
    return asyncio.run(probe(url, **kw))


class ProbeRefusesThisNetwork(unittest.TestCase):

    def setUp(self):
        env = patch.dict(os.environ, {}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        self.upstream = Upstream()
        mock = self.upstream.patch()
        mock.start()
        self.addCleanup(mock.stop)

    def assertRefused(self, url: str, **kw):
        with self.assertRaises(ProbeFailed) as caught:
            run_probe(url, **kw)
        self.assertIn("own network", str(caught.exception))
        return caught.exception

    def test_loopback_is_refused_before_the_listener_is_reached(self):
        hits = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                hits.append(self.path)
                body = json.dumps(RECORDS).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with patch.object(probe_module.httpx, "AsyncClient", httpx.AsyncClient):
            self.assertRefused("http://127.0.0.1:%d/items" % server.server_address[1])
        self.assertEqual(hits, [])

    def test_the_cloud_metadata_endpoint(self):
        with resolving({}):
            self.assertRefused("http://169.254.169.254/latest/meta-data/")
        self.assertEqual(self.upstream.sent, [])

    def test_a_metadata_address_that_is_not_private_is_still_not_global(self):
        # Alibaba Cloud's metadata service is 100.100.100.200, inside the
        # carrier-grade NAT block: not is_private, and not a public address.
        with resolving({}):
            self.assertRefused("http://100.100.100.200/latest/meta-data/")
        self.assertEqual(self.upstream.sent, [])

    def test_a_service_on_the_compose_network(self):
        with resolving({"minio": "172.18.0.4"}):
            self.assertRefused("http://minio:9000/percolate/")
        self.assertEqual(self.upstream.sent, [])

    def test_a_redirect_from_a_public_host_to_the_metadata_endpoint(self):
        with resolving({"api.example.com": PUBLIC}):
            self.assertRefused("https://api.example.com/to/http/169.254.169.254/latest/meta-data")
        self.assertEqual(self.upstream.hosts(), ["api.example.com"])

    def test_a_redirect_to_a_name_that_resolves_inside(self):
        with resolving({"api.example.com": PUBLIC, "postgrest": "172.18.0.3"}):
            self.assertRefused("https://api.example.com/to/http/postgrest/rpc")
        self.assertEqual(self.upstream.hosts(), ["api.example.com"])

    def test_a_public_endpoint_is_still_described(self):
        # The control: a refusal that also refused this would pass every test above.
        with resolving({"api.example.com": PUBLIC}):
            report = run_probe("https://api.example.com/items")
        self.assertEqual(report["kind"], "records")
        self.assertEqual(report["observed"]["record_count"], 2)

    def test_a_public_redirect_is_still_followed(self):
        with resolving({"api.example.com": PUBLIC, "cdn.example.com": PUBLIC}):
            report = run_probe("https://api.example.com/to/https/cdn.example.com/items")
        self.assertEqual(report["url"], "https://cdn.example.com/items")
        self.assertEqual(self.upstream.hosts(), ["api.example.com", "cdn.example.com"])

    def test_an_endpoint_the_operator_sanctioned_is_not_probed(self):
        # REM-555. LLM_URL, P8_AGENT_URL and P8_TEMPLATE_ENV name endpoints the
        # worker may reach. A probe URL is typed by a caller, so the same list
        # let any signed-in caller read an internal model server through it.
        env = {"LLM_URL": "http://model:8000", "P8_AGENT_URL": "http://agent:8080",
               "P8_TEMPLATE_ENV": "SEARCH_URL", "SEARCH_URL": "http://search:7700"}
        hosts = {"model": "10.0.0.4", "agent": "10.0.0.6", "search": "10.0.0.5"}
        for url in ("http://model:8000/v1/models", "http://agent:8080/v1/chat/completions",
                    "http://search:7700/items"):
            with self.subTest(url=url), patch.dict(os.environ, env), resolving(hosts):
                self.assertRefused(url)
        self.assertEqual(self.upstream.sent, [])

    def test_the_worker_still_reaches_what_the_operator_named(self):
        # The control: the exemption is withdrawn from caller URLs only.
        env = {"LLM_URL": "http://model:8000"}
        with patch.dict(os.environ, env), resolving({"model": "10.0.0.4"}):
            refuse_internal_egress("http://model:8000/v1/chat/completions")
            with self.assertRaises(EgressRefused):
                refuse_internal_egress("http://model:8000/v1/models", sanctioned=False)

    def test_a_named_credential_does_not_follow_a_redirect_to_another_origin(self):
        # Following redirects by hand means deciding what a hop carries. httpx
        # stripped Authorization on a cross-origin hop and forwarded every other
        # header, so an `auth_type: header` credential went wherever the
        # endpoint redirected. Neither form goes now.
        env = {"PROBE_KEY": "s3cret-value",
               "P8_CREDENTIAL_ORIGINS": json.dumps({"PROBE_KEY": ["https://api.example.com"]})}
        for auth_type in ("bearer", "header"):
            with self.subTest(auth_type), patch.dict(os.environ, env), \
                    resolving({"api.example.com": PUBLIC, "other.example.com": PUBLIC}):
                self.upstream.sent.clear()
                run_probe("https://api.example.com/to/https/other.example.com/items",
                          auth_type=auth_type, credential_ref="PROBE_KEY")
                first, second = self.upstream.sent
                self.assertIn("s3cret-value", " ".join(first.headers.values()))
                self.assertNotIn("s3cret-value", " ".join(second.headers.values()))


class FakeConn:
    def __init__(self, url: str):
        self.url, self.committed = url, []

    async def fetchval(self, sql, *args):
        if "begin_api_pull" in sql:
            return json.dumps({"config": {"url": self.url, "pagination": "none",
                                          "watermark_type": "none", "records_path": "$"},
                               "revision": 1})
        self.committed.append(sql)
        return json.dumps({"revision": 2, "inserted": 2, "updated": 0, "unchanged": 0,
                           "receipt": {"pulled": True}})


class PullerRefusesThisNetwork(unittest.TestCase):

    def setUp(self):
        env = patch.dict(os.environ, {}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        self.upstream = Upstream()
        mock = self.upstream.patch()
        mock.start()
        self.addCleanup(mock.stop)

    def pull(self, url: str):
        conn = FakeConn(url)

        @asynccontextmanager
        async def service():
            yield conn

        with patch.object(api_module, "as_service", service):
            result = asyncio.run(api_module.api_pull(
                {"source_id": "00000000-0000-0000-0000-000000000001"},
                {"_task_id": "00000000-0000-0000-0000-000000000002", "_worker_id": "w"}))
        return result, conn

    def test_a_source_on_the_metadata_endpoint_is_refused_before_any_request(self):
        with resolving({}), self.assertRaises(TerminalError) as caught:
            self.pull("http://169.254.169.254/latest/meta-data/items")
        self.assertIn("own network", str(caught.exception))
        self.assertEqual(self.upstream.sent, [])

    def test_a_source_on_the_compose_network_is_refused(self):
        with resolving({"postgrest": "172.18.0.3"}), self.assertRaises(TerminalError):
            self.pull("http://postgrest:3000/rpc/items")
        self.assertEqual(self.upstream.sent, [])

    def test_a_public_source_still_pulls(self):
        with resolving({"api.example.com": PUBLIC}):
            result, conn = self.pull("https://api.example.com/items")
        self.assertEqual(result, {"result": {"pulled": True}})
        self.assertEqual(self.upstream.hosts(), ["api.example.com"])
        self.assertEqual(len(conn.committed), 1)


if __name__ == "__main__":
    unittest.main()
