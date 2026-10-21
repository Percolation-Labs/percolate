"""The person's own agent reads conversations and judges, with no second model (REM-1056).

The memory tutorials made Percolate call models of its own: one to read a
conversation (reflect_session) and one to judge whether two names are one
thing. A person whose agent is connected over MCP already has a reader and a
judge. These tools hand that agent the same work, as the person: every call
goes to PostgREST with the MCP request's own Authorization, so row policy
decides what the agent may read, land and decide, exactly as it would for the
person at a psql prompt. There is no logic here beyond naming the arguments;
the rules live in the SQL the calls reach.

  read_session        agentic.session_messages     one window per thing the user wrote
  land_message_facts  agentic.land_message_facts   one message's facts, landed as agent:<you>
  list_judgements     aiq.list_judgements           what waits for a judge
  claim_judgement     aiq.claim_judgement           one item, its evidence and how to decide it
  decide_judgement    aiq.complete_judgement        a verdict with its reason, tier agent
  release_judgement   aiq.release_judgement         give a claimed item back undecided
"""

from __future__ import annotations

import json
from typing import Any, Callable

# (MCP tool name) -> (description, JSON Schema for the arguments, PostgREST
# schema, SQL function, arguments -> SQL payload)
_Spec = tuple[str, dict[str, Any], str, str, Callable[[dict[str, Any]], dict[str, Any]]]

TOOLS: dict[str, _Spec] = {
    "read_session": (
        "Read a conversation you may read: one window per message the user wrote, with its message_id, when it "
        "was said, and the words. The assistant's turns are left out, because only what the user wrote is evidence "
        "about them. Use it before land_message_facts.",
        {"type": "object", "required": ["session_id"],
         "properties": {"session_id": {"type": "string", "description": "the session's uuid"}}},
        "agentic", "session_messages",
        lambda a: {"p_session": a["session_id"]},
    ),
    "land_message_facts": (
        "Record what one user message says, as a small graph, in the memory you share with that conversation. "
        "graph is {\"nodes\": [{\"k\": <kind>, \"n\": <name>}...], \"edges\": [{\"s\": <node index>, \"t\": "
        "<node index>, \"r\": <relation>}...]}, with relations from the registered vocabulary. Each fact cites "
        "the message and holds from when it was said, and is recorded as your agent's. Refused for a message you "
        "may not read or one the assistant wrote. A name it cannot resolve is kept soft and reaches the judgement "
        "queue at the next reconcile.",
        {"type": "object", "required": ["message_id", "graph"],
         "properties": {"message_id": {"type": "string"},
                        "graph": {"type": "object", "required": ["nodes"],
                                  "properties": {"nodes": {"type": "array"}, "edges": {"type": "array"}}}}},
        "agentic", "land_message_facts",
        lambda a: {"p_message_id": a["message_id"], "p_graph": a["graph"]},
    ),
    "list_judgements": (
        "List the judgements waiting for a judge that you may see: what each is about and its status. Read-only.",
        {"type": "object",
         "properties": {"status": {"type": "string", "enum": ["open", "claimed", "decided", "to_human"],
                                   "default": "open"},
                        "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 50}}},
        "aiq", "list_judgements",
        lambda a: {"p_status": a.get("status", "open"), "p_limit": a.get("limit", 50)},
    ),
    "claim_judgement": (
        "Claim one judgement to decide: it is held for you for a while, and comes with its evidence (the name, "
        "what was said about it, the candidates it might be, with summaries) and how_to_decide, which names the "
        "verdicts you may give and the candidate ids a bind may name. A challenge is one of the person's own "
        "claims, just saved, with the claims already in the graph nearest it that they may read. Give an id to "
        "claim that one; otherwise the next open item. Answers {\"empty\": true} when nothing waits.",
        {"type": "object",
         "properties": {"id": {"type": "string", "description": "a judgement id from list_judgements"},
                        "kinds": {"type": "array", "items": {"type": "string",
                                                             "enum": ["bind", "merge", "withdraw", "challenge"]}}}},
        "aiq", "claim_judgement",
        lambda a: {"p_id": a.get("id"), "p_kinds": a.get("kinds")},
    ),
    "decide_judgement": (
        "Decide a judgement you hold, with your reason. verdict is one of the shapes how_to_decide named: "
        "{\"decision\":\"bind\",\"target\":\"<candidate node id>\"}, {\"decision\":\"distinct\"}, "
        "{\"decision\":\"none\"}, or {\"decision\":\"human\"} to hand it to a person. A challenge is decided "
        "{\"decision\":\"relate\",\"relations\":[{\"target\":\"<candidate claim id>\",\"predicate\":\"same_as\","
        "\"spans\":{...}}]} -- each relation asserted as you, so it lands proposed until the person confirms it -- "
        "or none. Recorded as decided by your agent, with the reason, and undoable. Refused once your hold has "
        "lapsed: claim it again.",
        {"type": "object", "required": ["id", "verdict", "reason"],
         "properties": {"id": {"type": "string"},
                        "verdict": {"type": "object", "required": ["decision"],
                                    "properties": {"decision": {"type": "string",
                                                                "enum": ["bind", "distinct", "none", "human",
                                                                         "relate"]},
                                                   "target": {"type": "string"},
                                                   "relations": {"type": "array", "items": {
                                                       "type": "object", "required": ["target", "predicate"],
                                                       "properties": {"target": {"type": "string"},
                                                                      "predicate": {"type": "string"},
                                                                      "spans": {"type": "object"}}}}}},
                        "reason": {"type": "string", "minLength": 1}}},
        "aiq", "complete_judgement",
        # The tier is the agent's, always: a person decides through the
        # product, and a configured model is not this tool.
        lambda a: {"p_id": a["id"], "p_verdict": a["verdict"], "p_reason": a["reason"], "p_tier": "agent"},
    ),
    "release_judgement": (
        "Give back a judgement you claimed without deciding it; it goes back to waiting and nothing is recorded. "
        "Use it when you are not sure, rather than guessing.",
        {"type": "object", "required": ["id"], "properties": {"id": {"type": "string"}}},
        "aiq", "release_judgement",
        lambda a: {"p_id": a["id"]},
    ),
}


def describe() -> list[dict[str, Any]]:
    """The MCP tool descriptors, in the order above."""
    return [{"name": name, "description": desc, "inputSchema": schema}
            for name, (desc, schema, _profile, _fn, _args) in TOOLS.items()]


def call(up: Any, name: str, arguments: dict[str, Any], authorization: str | None) -> dict[str, Any]:
    """Run one tool as the caller; an MCP ``tools/call`` result, ``isError`` on any refusal."""
    _desc, schema, profile, fn, to_args = TOOLS[name]
    missing = [k for k in schema.get("required", []) if arguments.get(k) in (None, "")]
    if missing:
        # A tool result, not a protocol error: the model left out an argument,
        # which it can see and correct.
        return {"isError": True, "content": [{"type": "text", "text": f"{name} needs {', '.join(missing)}"}]}
    doc, err = up.rpc(fn, to_args(arguments), authorization, profile=profile)
    if err is not None:
        return {"isError": True, "_meta": {"errorKind": err["kind"]},
                "content": [{"type": "text", "text": json.dumps(err)}]}
    return {"content": [{"type": "text", "text": json.dumps(doc)}],
            "structuredContent": doc if isinstance(doc, dict) else {"result": doc}}
