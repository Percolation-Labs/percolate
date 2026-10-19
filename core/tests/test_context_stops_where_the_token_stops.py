"""The caller's ambient context goes only where their token may (REM-148).

`X-P8-User-Id`, `X-P8-Session-Id` and `X-P8-Parent-Run-Id` name the person
asking, their conversation and the run it belongs to. They were forwarded to
every tool destination, so on 2026-09-12 `httpbin.org` -- registered as a tool
server and absent from `P8_TOOL_AUTH_ORIGINS` -- echoed back a real
user id and session id from a live stack, while `outbound_headers` was correctly
refusing that same request the caller's token.

Every case here is checked in BOTH directions. A rule that only ever
strips is satisfied by stripping everything, and that would break delegation:
the gateway is first-party, is in the list on purpose, and a delegated call that
arrives without the caller is the defect REM-96 fixed.
"""
import asyncio
import unittest

from percolate_core.agentic.contracts import ToolServer
from percolate_core.agentic.tools.auth import caller_credentials, outbound_headers

FIRST_PARTY = "http://gateway:8765"
THIRD_PARTY = "https://httpbin.org"
ORIGINS = (FIRST_PARTY, "http://postgrest:3000")
TOKEN = "Bearer jwt-for-the-person-asking"

CONTEXT = {
    "X-P8-User-Id": "01a09792-8d4a-7432-a5eb-83046becb78d",
    "X-P8-Session-Id": "01a0979b-82bb-7329-8541-f40e453d1aa8",
    "X-P8-Parent-Run-Id": "01a0979c-b8eb-710f-91a8-289542ac196f",
    "X-P8-Locale": "en-US",
    "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    "Accept": "application/json",
}


def server(url: str) -> ToolServer:
    return ToolServer(name="probe", kind="openapi", url=url + "/openapi.json")


def sent(url: str, *, token: str | None = TOKEN) -> dict:
    async def go():
        with caller_credentials(token, ORIGINS):
            return await outbound_headers(server(url), dict(CONTEXT), url=url + "/call")
    return asyncio.run(go())


class ThirdParty(unittest.TestCase):
    """The measured leak. Each header the tour caught is named individually."""

    def setUp(self):
        self.out = sent(THIRD_PARTY)

    def test_the_user_id_does_not_leave(self):
        self.assertNotIn("X-P8-User-Id", self.out)

    def test_the_session_id_does_not_leave(self):
        self.assertNotIn("X-P8-Session-Id", self.out)

    def test_the_parent_run_id_does_not_leave(self):
        self.assertNotIn("X-P8-Parent-Run-Id", self.out)

    def test_nothing_x_p8_leaves_at_all(self):
        """The block, not a list of three, so a new header is covered on the day it is added."""
        self.assertEqual([k for k in self.out if k.lower().startswith("x-p8-")], [])

    def test_the_token_still_does_not_leave(self):
        """The half that already worked. A regression here would be worse than the bug."""
        self.assertNotIn("Authorization", self.out)

    def test_traceparent_survives(self):
        """W3C, not ours, and carries no identity -- propagation is the point of it."""
        self.assertEqual(self.out["traceparent"], CONTEXT["traceparent"])

    def test_ordinary_headers_survive(self):
        self.assertEqual(self.out["Accept"], "application/json")


class FirstParty(unittest.TestCase):
    """The control. Stripping everything would satisfy the class above and break delegation."""

    def setUp(self):
        self.out = sent(FIRST_PARTY)

    def test_the_context_reaches_a_bound_origin(self):
        for k in ("X-P8-User-Id", "X-P8-Session-Id", "X-P8-Parent-Run-Id", "X-P8-Locale"):
            self.assertEqual(self.out[k], CONTEXT[k], k)

    def test_the_caller_token_reaches_a_bound_origin(self):
        """REM-96: a delegated call arrives as the person who asked."""
        self.assertEqual(self.out["Authorization"], TOKEN)


class Edges(unittest.TestCase):
    def test_a_redirect_off_the_registered_origin_takes_the_context_with_it(self):
        """`same_origin` already governed the token; it governs the context too."""
        async def go():
            with caller_credentials(TOKEN, ORIGINS):
                return await outbound_headers(
                    server(FIRST_PARTY), dict(CONTEXT), url=THIRD_PARTY + "/call")
        out = asyncio.run(go())
        self.assertEqual([k for k in out if k.lower().startswith("x-p8-")], [])
        self.assertNotIn("Authorization", out)

    def test_an_anonymous_caller_to_a_bound_origin_still_carries_context(self):
        """No token is not no policy: the origin list is configured either way."""
        out = sent(FIRST_PARTY, token=None)
        self.assertEqual(out["X-P8-Session-Id"], CONTEXT["X-P8-Session-Id"])
        self.assertNotIn("Authorization", out)

    def test_outside_any_request_nothing_ambient_leaves(self):
        """No `caller_credentials` scope means no list to check, so nothing is bound."""
        async def go():
            return await outbound_headers(
                server(THIRD_PARTY), dict(CONTEXT), url=THIRD_PARTY + "/call")
        out = asyncio.run(go())
        self.assertEqual([k for k in out if k.lower().startswith("x-p8-")], [])

    def test_the_check_is_case_insensitive(self):
        """httpx lowercases on the wire; a dict built by hand may not have."""
        async def go():
            with caller_credentials(TOKEN, ORIGINS):
                return await outbound_headers(
                    server(THIRD_PARTY), {"x-p8-user-id": "u", "X-p8-Session-Id": "s"},
                    url=THIRD_PARTY + "/call")
        self.assertEqual(asyncio.run(go()), {})


if __name__ == "__main__":
    unittest.main()
