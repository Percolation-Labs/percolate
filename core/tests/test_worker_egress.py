"""The worker cannot be pointed back at the network it is sitting on.

REM-91 item 6. `http_call`'s `url` is resolved from `{{run.*}}` and
`{{steps.*}}` — whatever started the run and whatever the last step returned,
which on the ingestion path includes text taken out of an uploaded document. The
worker sits on the compose network beside Postgres, MinIO and PostgREST with
`P8_S3_KEY` in its environment, and made whatever request it was given.

`credential_for` already stops a *named* secret travelling somewhere it was not
bound to, and `TEMPLATE_ENV` already stops `{{env.X}}` putting a secret in a
body. Neither says anything about an unauthenticated GET to a service that
answers on this network because the caller is on it — which is enough to read an
object store, or a cloud metadata endpoint.

No network: `getaddrinfo` is patched, so these assert the decision rather than
the resolver. The one test that does resolve is the loopback control, which
needs no DNS.
"""
import os
import unittest
from unittest.mock import patch

from percolate_core.worker.http import build_request, refuse_internal_egress
from percolate_core.worker.templates import TerminalError


def _resolves_to(address: str):
    """Patch getaddrinfo so a hostname answers with one chosen address."""
    def fake(host, port, *args, **kwargs):
        return [(2, 1, 6, "", (address, port))]
    return patch("socket.getaddrinfo", side_effect=fake)


class InternalAddressesAreRefused(unittest.TestCase):

    def test_the_cloud_metadata_endpoint(self):
        with patch.dict(os.environ, {}, clear=True), _resolves_to("169.254.169.254"):
            with self.assertRaises(TerminalError) as caught:
                refuse_internal_egress("http://169.254.169.254/latest/meta-data/")
        self.assertIn("own network", str(caught.exception))

    def test_a_service_on_the_compose_network(self):
        with patch.dict(os.environ, {}, clear=True), _resolves_to("172.18.0.4"):
            with self.assertRaises(TerminalError):
                refuse_internal_egress("http://minio:9000/percolate/secrets")

    def test_loopback(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(TerminalError):
                refuse_internal_egress("http://127.0.0.1:5432/")

    def test_a_public_address_is_allowed(self):
        with patch.dict(os.environ, {}, clear=True), _resolves_to("93.184.216.34"):
            refuse_internal_egress("https://api.example.com/v1/things")

    def test_a_name_that_does_not_resolve_is_left_alone(self):
        # It reaches nothing, so there is nothing to refuse -- and the request
        # then fails the way it always did, with httpx's own retryable error.
        # Raising here instead turned fourteen existing tests red: they drive
        # the worker with hostnames like `model.example` and a mocked transport,
        # and a check that resolves for real made them need DNS. A check that
        # changes what the code under it means is worse than the gap it closes.
        import socket
        with patch.dict(os.environ, {}, clear=True), \
                patch("socket.getaddrinfo", side_effect=socket.gaierror("nope")):
            refuse_internal_egress("https://nowhere.invalid/")


class SanctionedEndpointsStillWork(unittest.TestCase):
    """The internal destinations a deployment names are exactly the ones it gets."""

    def test_the_agent_runtime_is_reachable_because_it_is_configured(self):
        env = {"P8_AGENT_URL": "http://agent:8080"}
        with patch.dict(os.environ, env, clear=True), _resolves_to("172.18.0.9"):
            refuse_internal_egress("http://agent:8080/v1/chat/completions")

    def test_the_same_address_is_refused_when_nobody_named_it(self):
        # The control for the test above: it is the naming that allows it, not
        # the address being harmless.
        with patch.dict(os.environ, {}, clear=True), _resolves_to("172.18.0.9"):
            with self.assertRaises(TerminalError):
                refuse_internal_egress("http://agent:8080/v1/chat/completions")

    def test_p8_template_env_extends_it(self):
        env = {"P8_TEMPLATE_ENV": "SEARCH_URL", "SEARCH_URL": "http://search:7700"}
        with patch.dict(os.environ, env, clear=True), _resolves_to("10.0.0.5"):
            refuse_internal_egress("http://search:7700/indexes")

    def test_a_different_port_on_a_named_host_is_not_sanctioned(self):
        env = {"P8_AGENT_URL": "http://agent:8080"}
        with patch.dict(os.environ, env, clear=True), _resolves_to("172.18.0.9"):
            with self.assertRaises(TerminalError):
                refuse_internal_egress("http://agent:5432/")


class TheCheckIsOnTheResolvedUrl(unittest.TestCase):

    def test_build_request_refuses_after_templating(self):
        # The author wrote a template; what matters is what it resolved to.
        spec = {"url": "http://{{run.host}}/x", "method": "GET"}
        ctx = {"run": {"host": "169.254.169.254"}}
        with patch.dict(os.environ, {}, clear=True), _resolves_to("169.254.169.254"):
            with self.assertRaises(TerminalError):
                build_request(spec, ctx)

    def test_a_url_that_is_not_http_is_refused(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(TerminalError):
                refuse_internal_egress("file:///etc/passwd")


if __name__ == "__main__":
    unittest.main()
