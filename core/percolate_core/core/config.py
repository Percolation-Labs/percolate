"""Configuration, from the environment only.

One place, so a variable means the same thing to every service and a missing
one fails with the same message.

Credentials are referenced by NAME, never stored in the database
(`credential_ref` on an http_call task names an environment variable this
process resolves). That is what keeps `workflow.tasks` inspectable and
replayable: a dump of the table contains the reference, never the secret.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


class ConfigError(RuntimeError):
    """A required setting is absent. Raised at startup, never mid-request."""


class TerminalError(Exception):
    """A failure that will recur identically on every retry.

    Defined here rather than in ``worker.templates``, which re-exports it, so
    that ``core.credentials`` can refuse a send with an error the worker loop
    already treats as terminal -- a credential bound to another origin is
    bound to it on the fifth attempt too -- without core importing the worker.
    """


def required(name: str, why: str) -> str:
    v = os.environ.get(name)
    if not v:
        raise ConfigError(f"{name} is not set -- {why}")
    return v


def optional(name: str, default: str | None = None) -> str | None:
    return os.environ.get(name, default)


def credential(ref: str) -> str:
    """Resolve a credential reference to its value.

    Tries the name as given and upper-cased, because a workflow author writing
    `credential_ref: llm_api_key` and an operator setting `LLM_API_KEY` are both
    doing the obvious thing.

    This answers "what is the secret", not "may it go there". Anything that
    SENDS a credential calls ``core.credentials.credential_for(ref, url)``,
    which checks the destination first and then calls this.
    """
    v = os.environ.get(ref) or os.environ.get(ref.upper())
    if not v:
        raise ConfigError(
            f"credential_ref '{ref}' is not set in this process's environment"
        )
    return v


def dsn() -> str:
    """The database every part of this process connects to. ONE precedence.

    There were three. `core/identity.open_pool` read `P8_DSN` then
    `P8_DATABASE_URL`; `agentic/settings.py` read them the other way round and
    fell back to `postgresql://p8:p8@localhost:5500/p8agentic`; and this
    function required `P8_DSN` alone and had no callers at all. A process that
    opened the core pool AND ran the agent runtime with both variables set to
    different databases got two databases, and nothing said so.

    `P8_DATABASE_URL` WINS, which is the agent runtime's order rather than the
    pool's, and it is the one with an argument behind it: it is the specific
    name, so a deployment that sets it is pointing this process somewhere other
    than the shared DSN on purpose. The pool's order was undocumented.

    NO SILENT DEFAULT. The localhost fallback cost a deployment already: `agent
    serve` restart-looped on `Connect call failed ('127.0.0.1', 5500)` in a
    stack where every other service had connected fine, because this runtime
    read one name, found it unset, and quietly used a database that was not
    there. An unset database is a startup failure with a message, not a guess.
    """
    v = dsn_if_set()
    if not v:
        raise ConfigError(
            "neither P8_DATABASE_URL nor P8_DSN is set -- every service connects "
            "to Postgres, and this process will not guess a database")
    return v


def dsn_if_set() -> str | None:
    """The same precedence, for a caller that is not connecting yet.

    Two names and ONE rule: `dsn()` is this plus the refusal. It exists because
    a settings object is built in places that never open a connection -- every
    test of CORS parsing constructs one -- and raising there would move the
    failure away from the thing that actually cannot proceed. The process that
    connects calls `dsn()` and gets the message; the process that is only
    reading its own configuration gets None and carries on.
    """
    return os.environ.get("P8_DATABASE_URL") or os.environ.get("P8_DSN")


@dataclass(frozen=True)
class S3Settings:
    """Where object storage is, and who this process is to it.

    SETTINGS, NOT POLICY, and the split is the point. Three modules read these
    five variables their own way, and two of them disagreed about the endpoint's
    default while a third disagreed about which bucket. What they do NOT
    disagree about is what to do when the credentials are missing, and they
    should not be made to: the Content Server raises, because a content server
    without storage is broken; `lake()` returns None, because a refine step over
    inline rows needs no object storage at all. Both are right. So this owns the
    reading and each caller keeps its own answer to "and if it is absent?".
    """

    endpoint: str
    key: str | None
    secret: str | None
    region: str
    bucket: str

    @property
    def host(self) -> str:
        """The endpoint without its scheme -- what DuckDB's `s3_endpoint` wants."""
        return self.endpoint.split("://", 1)[-1]

    @property
    def use_ssl(self) -> bool:
        return self.endpoint.startswith("https")


def s3(bucket: str | None = None) -> S3Settings:
    """Object storage settings. `bucket` overrides `P8_BUCKET` for a caller that
    has its own (the lake reads `P8_LAKE_BUCKET` first, and that stays its
    business rather than becoming a second variable everyone has to know)."""
    return S3Settings(
        endpoint=os.environ.get("P8_S3_ENDPOINT", "http://localhost:9000"),
        key=os.environ.get("P8_S3_KEY") or None,
        secret=os.environ.get("P8_S3_SECRET") or None,
        region=os.environ.get("P8_S3_REGION", "us-east-1"),
        bucket=bucket or os.environ.get("P8_BUCKET", "p8-content"),
    )
