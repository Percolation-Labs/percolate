"""Keep a copy of a public page as somebody's research evidence.

A research package cites sources by link, and a link is a claim about a page
that can change or vanish. `content.capture_snapshot` pins the exact bytes a
source was read from, but only bytes that are already stored, and nothing a
person could reach stored any (REM-239). This is the missing step: one GET,
stored content-addressed, registered through `content.register_evidence` as the
person who asked.

THE POLICY IS AN INTERIM ONE, and it is the database's, not this module's.
Sirsh set it on 2026-09-14 (REM-242): anybody who may write research may keep a
copy of a public page, limited only by bytes, until the policy is reviewed
(REM-245). `register_evidence` asks `research:insert` and charges the
`evidence_bytes` budget; this module decides nothing about who may.

WHY HERE. The Content Server is the process allowed to make a request to
somewhere else and to write object storage -- `probe.py` gives the argument in
full -- so a second fetcher in the application would be a second place holding
both. The request is the probe's: every hop checked against `core.egress` before
it is made, no credentials sent anywhere, and a byte and time cap.

A PAGE OVER THE CAP IS REFUSED, NOT TRUNCATED. The probe keeps the first two
megabytes because it only needs a page's shape. A truncated copy pinned as
evidence would claim to be the page, which is the one thing evidence must not do.
"""

from __future__ import annotations

from urllib.parse import urldefrag

import httpx

from ..core import TerminalError
from .probe import ProbeFailed, _fetch

MAX_BYTES = 10_000_000
"""A long article with its images inlined, or a typical paper as a PDF. Past
this a copy is refused with the size named, and the source stays unverified."""

USER_AGENT = "Percolate-Evidence (+https://percolate.sh; one request to keep a copy of a cited page)"
"""Says what it is and why, so a site's operator can tell it from a crawler."""

ACCEPT = "text/html, application/xhtml+xml, application/pdf;q=0.9, text/plain;q=0.8, */*;q=0.5"


class EvidenceRefused(TerminalError):
    """The page was not kept. The message is the reason a person is shown."""


async def fetch(url: str) -> tuple[bytes, str]:
    """The page's bytes and its media type, or EvidenceRefused naming why not.

    The fragment is dropped before the request: it never reaches a server, and
    the origin rule the probe shares refuses a URL carrying one.
    """
    target = urldefrag(url).url
    try:
        response, body, over = await _fetch(target, {"Accept": ACCEPT, "User-Agent": USER_AGENT},
                                            limit=MAX_BYTES + 1)
    except ProbeFailed as exc:
        raise EvidenceRefused(str(exc)) from None
    except httpx.HTTPError as exc:
        raise EvidenceRefused(f"The page could not be reached ({type(exc).__name__}).") from None
    if response.status_code >= 400:
        raise EvidenceRefused(f"The page answered {response.status_code}, so there was nothing to keep.")
    if over:
        raise EvidenceRefused(f"The page is larger than {MAX_BYTES // 1_000_000} MB, so no copy was kept.")
    if not body:
        raise EvidenceRefused("The page was empty, so there was nothing to keep.")
    media = response.headers.get("content-type", "").split(";")[0].strip().lower()
    return body, media or "application/octet-stream"
