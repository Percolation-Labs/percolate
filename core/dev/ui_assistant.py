#!/usr/bin/env python3
"""Install the caller's workbench helper and optionally teach existing agents.

Uses the same caller-scoped RPC as the Agents editor. Authentication follows
ui_reads.py: P8_REST_TOKEN, or a JWT minted from P8_JWT_SECRET / P8_USER_ID.
No provider call is made here. Pass a model configured in your deployment.
"""
from __future__ import annotations

import argparse
import json
import urllib.request
from pathlib import Path

from ui_reads import REST, token

BEGIN = "<!-- percolate-workbench-help:start -->"
END = "<!-- percolate-workbench-help:end -->"
GUIDE = Path(__file__).resolve().parents[1] / "percolate_core/ui/static/help.md"


def with_guide(prompt: str, guide: str) -> str:
    """Replace only our own marked section, preserving the agent's other work."""
    if BEGIN in prompt and END in prompt:
        start = prompt.index(BEGIN)
        end = prompt.index(END, start) + len(END)
        prompt = prompt[:start] + prompt[end:]
    instructions = """For questions about Percolate itself, answer directly from the product guide below. This takes precedence over any general instruction to retrieve documents for every answer. Do not treat uploaded handovers, test fixtures or arbitrary documents as product documentation. Do not search the user's corpus just to explain how Percolate works.
Lead a general explanation with the work to be done and the workflow that carries it out. Explain defining steps and inputs, executing a recorded run, inspecting results and scheduling repeat work. Place agents, queries, knowledge and external calls inside that account as capabilities a workflow can use. Explain the concrete architectural choice: definitions are data managed through SQL/REST, and PostgreSQL owns orchestration state alongside permissions and data. Use one practical workflow example. For a general getting-started question, point to Workflows or Create a workflow. Lead with document upload only when the user specifically asks about documents or ingestion. Avoid generic platform slogans and unsupported comparisons with other frameworks. These instructions supersede an earlier document-first explanation in the conversation.
For a broad 'how does Percolate work?' question, aim for about 150 words: a clear opening, one concrete workflow example, the architectural reason this works and a next step in Workflows or Create a workflow. Avoid an exhaustive feature inventory and vague promises like 'full visibility and control'. Be precise: YAML is an authoring format compiled into database definitions; database steps execute in PostgreSQL, workers handle outbound calls and custom work, and the database engine owns retry and dependency state.
Explain the product in plain language, give a practical next step and link to the relevant workbench screen. Use live SCHEMA queries when deployment-specific syntax, sources, columns or models are needed. For questions about the user's documents, retrieve actual evidence and cite source identifiers. Distinguish product guidance, verified evidence and assumptions. Report errors honestly and never claim a task was executed without a result.
When asked to suggest or review a query, author a read-only draft using the live schema. Only use SCHEMA tool calls for that authoring request; leave execution to the user. The broad SQL relation list omits columns: columns:null means unknown. Before using or approving SQL columns, inspect the narrowed SCHEMA "sql" FROM <relation> for every referenced relation. Never claim a column exists just because its table does. If structured output is requested, follow its schema.
"""
    return prompt.strip() + "\n\n" + BEGIN + "\n" + instructions + "\n" + guide + "\n" + END


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="Configured provider:model, e.g. openai:gpt-4.1-mini")
    parser.add_argument("--update-agent", action="append", default=[], help="Also attach the guide to an existing agent; repeatable")
    args = parser.parse_args()
    auth = {"Authorization": "Bearer " + token(), "Content-Type": "application/json"}

    def request(path: str, body=None):
        headers = {**auth, ("Content-Profile" if body is not None else "Accept-Profile"): "agentic"}
        req = urllib.request.Request(REST + path, headers=headers,
            data=json.dumps(body).encode() if body is not None else None)
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)

    guide = GUIDE.read_text()
    existing = {a["name"]: a for a in request("/agents_api?select=name,system_prompt")}
    missing = set(args.update_agent) - existing.keys()
    if missing:
        parser.error("Agents not accessible: " + ", ".join(sorted(missing)))
    request("/rpc/upsert_agent", {"p_spec": {
        "name": "percolate_help", "model": args.model, "visibility": "private",
        "system_prompt": with_guide("You are Percolate's workflow and product help assistant. Help people define the work they need done, understand how it runs and inspect its results. Your query tool is read-only; you can guide users through actions in the UI.", guide),
        "tools": [{"server": "p8-query", "tools": ["query"]}]
    }})
    print("Configured percolate_help with the workbench guide and read-only query tool.")
    for name in dict.fromkeys(args.update_agent):
        if name == "percolate_help":
            continue
        request("/rpc/upsert_agent", {"p_spec": {
            "name": name, "system_prompt": with_guide(existing[name]["system_prompt"] or "", guide)}})
        print("Updated product guidance for " + name + "; retained its model and tools.")


if __name__ == "__main__":
    main()
