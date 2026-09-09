"""YAML out, for `render` — the reviewable half.

Enough YAML for these two manifests and no more, hand-rolled for two reasons.
The first is the one `k8s/kind/manager.py` gives: JSON piped through
`kubectl apply` would be correct and unreadable, and `k8s/examples/` exists so
that a change to the generator is a diff in a pull request. The second is that
the checked-in examples are *annotated*, and a generic serialiser cannot emit a
comment — so `render` would produce the right bytes and lose every reason a
reader would look at them.

So the manifest stays one plain dict, and the prose hangs off it by path:
`NOTES` maps a tuple-path to the comment that precedes that key, `FLOW` names
the paths that render inline. One source of truth for what gets applied, one
table for what gets read.
"""

from __future__ import annotations


def scalar(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    # Quote what YAML would read as something other than a string. "1", "500m"
    # and "true" are the three that bite -- an unquoted "1" for
    # targetQueryValue is an int where KEDA's CRD wants a string.
    #
    # A colon is NOT in this list, and that is deliberate: a colon only
    # separates a mapping key when it is followed by a space, so
    # `image: ghcr.io/acme/x:1.4` is a plain scalar and quoting it is a diff
    # against the checked-in render for no gain.
    if (s == "" or s[0] in "&*?|-<>=!%@`{[" or ": " in s or s.endswith(":")
            or " #" in s
            or s.lower() in ("true", "false", "null", "yes", "no", "on", "off")
            or _numberish(s)):
        return '"' + s.replace('"', '\\"') + '"'
    return s


def _numberish(s: str) -> bool:
    try:
        float(s)
        return True
    except ValueError:
        return False


def _flow(v) -> str:
    """A list on one line: ["a", "b"]. Only for short lists of scalars."""
    return "[" + ", ".join(_flow_scalar(i) for i in v) + "]"


def _flow_scalar(v) -> str:
    # Inside flow style every string is quoted, which is what the examples do
    # and what keeps `["worker"]` from reading as a bare token list.
    if isinstance(v, str):
        return '"' + v.replace('"', '\\"') + '"'
    return scalar(v)


def dump(value, notes: dict | None = None, flow: set | None = None,
         quote: set | None = None, indent: int = 0, path: tuple = ()) -> str:
    notes = notes or {}
    flow = flow or set()
    quote = quote or set()
    pad = "  " * indent
    out: list[str] = []

    if isinstance(value, dict):
        for k, val in value.items():
            here = path + (k,)
            if here in notes:
                for line in notes[here].strip("\n").split("\n"):
                    out.append(f"{pad}# {line}".rstrip())
            if here in flow and isinstance(val, list):
                out.append(f"{pad}{k}: {_flow(val)}")
            elif here in quote:
                # Forced, because the CRD types this field as a string and a
                # value that only *happens* not to need quoting today is a
                # value that changes meaning the first time somebody edits it.
                out.append(f'{pad}{k}: "' + str(val).replace('"', '\\"') + '"')
            elif isinstance(val, (dict, list)) and val:
                out.append(f"{pad}{k}:")
                out.append(dump(val, notes, flow, quote, indent + 1, here))
            else:
                out.append(f"{pad}{k}: {scalar(val)}")
        return "\n".join(out)

    if isinstance(value, list):
        for i, item in enumerate(value):
            here = path + (i,)
            if isinstance(item, (dict, list)):
                body = dump(item, notes, flow, quote, indent + 1, here).split("\n")
                # A comment cannot ride on the `- ` line, so hoist any note on
                # the first key above the dash where it still reads correctly.
                lead = 0
                while lead < len(body) and body[lead].lstrip().startswith("#"):
                    out.append(pad + body[lead].lstrip())
                    lead += 1
                out.append(f"{pad}- " + body[lead].lstrip())
                out.extend(body[lead + 1:])
            else:
                out.append(f"{pad}- {scalar(item)}")
        return "\n".join(out)

    return f"{pad}{scalar(value)}"
