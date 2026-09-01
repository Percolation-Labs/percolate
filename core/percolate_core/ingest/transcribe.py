"""Audio to text, through whatever speaks the OpenAI transcription shape.

A LOCAL MODEL IS NOT THE DEFAULT, deliberately. faster-whisper is excellent
and it is a 100MB-2GB model download, a CTranslate2 build per platform, and a
first-run that silently fetches weights from the internet -- inside a worker
whose whole contract is that it does small, restartable units of work. The
default here is one HTTPS call to an endpoint the policy names, with the
credential resolved by NAME from this worker's environment exactly as an
http_call step's `credential_ref` is.

Pointing it at a local server is a URL, not a code path:

    transcribe: {endpoint: "http://whisper:9000/v1/audio/transcriptions",
                 model: "whisper-large-v3", credential: "LOCAL_NOOP"}

which is the same "one S3-compatible client, always" reasoning the Content
Server uses for storage -- one client, different configuration, never two code
paths to keep in step.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

from ..core import credential as resolve_credential
from .policy import TranscribePolicy

__all__ = ["transcribe"]

_MEDIA = {
    ".wav": "audio/wav", ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
    ".flac": "audio/flac", ".ogg": "audio/ogg", ".webm": "audio/webm",
    ".mp4": "video/mp4",
}


def transcribe(data: bytes, name: str, policy: TranscribePolicy) -> tuple[str, dict[str, Any]]:
    """(text, detail). Raises with the provider's own message on a refusal."""
    ext = os.path.splitext(name.lower())[1]
    files = {"file": (os.path.basename(name) or "audio" + ext,
                      data, _MEDIA.get(ext, "application/octet-stream"))}
    form: dict[str, str] = {"model": policy.model,
                            # verbose_json carries the duration and the detected
                            # language, which are worth keeping on the resource:
                            # "why is this transcript nonsense" is usually
                            # "it decided the language was Welsh".
                            "response_format": "verbose_json"}
    if policy.language:
        form["language"] = policy.language
    if policy.prompt:
        form["prompt"] = policy.prompt

    headers = {"Authorization": "Bearer " + resolve_credential(policy.credential)}
    with httpx.Client(timeout=300.0) as client:
        r = client.post(policy.endpoint, headers=headers, data=form, files=files)
        if r.status_code >= 400:
            raise RuntimeError(
                "transcription endpoint returned " + str(r.status_code) + ": "
                + r.text[:500])
        # A server that does not implement verbose_json answers with plain text
        # rather than failing, so accept both instead of insisting.
        try:
            body = r.json()
        except ValueError:
            return r.text.strip(), {"response_format": "text"}

    return (body.get("text") or "").strip(), {
        "language": body.get("language"),
        "duration_seconds": body.get("duration"),
        "model": policy.model,
    }
