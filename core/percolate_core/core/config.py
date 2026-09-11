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
    return required("P8_DSN", "every service connects to Postgres")
