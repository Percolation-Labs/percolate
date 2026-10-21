"""Apply a Percolate package: read its manifest, hand it to the database (REM-1105).

    percolate package apply PACKAGE [--owner USER_UUID] [--dsn DSN] [--dry-run]

Thin on purpose. The install is `percolate.apply_package(jsonb)` and lives in
the database; this reads YAML, inlines the files a manifest points at, applies
the package's own storage, and calls it. Everything that could be a decision --
ordering, pruning, what a missing section means -- is in the function, where a
client written in another language gets the same answer.

PACKAGE is a directory holding `manifest.yaml`, or the manifest file itself:
the UI's export is one file, and a package with storage or skills is a
directory.
"""
from __future__ import annotations

import json
import re
import uuid
from pathlib import Path
from typing import Any


class PackageError(Exception):
    """A package that cannot be applied as written, said before anything is written."""


def manifest_path(path: Path) -> Path:
    return path if path.is_file() else path / "manifest.yaml"


PATH_LIKE = re.compile(r"^[\w.\-]+(/[\w.\-]+)*\.\w+$")


def body_path(body: str) -> bool:
    """A skill's `body` names a file when it is one token shaped like a path.

    Prose stays prose: a body with a space or a line break is the instructions
    themselves, as one starting with `#` (a markdown heading) always was. A
    path that names no file is a typo, and installing it would hand the agent
    the path as its instructions.
    """
    return bool(PATH_LIKE.match(body.strip())) and not body.lstrip().startswith("#")


def check_refs(root: Path, m: dict[str, Any]) -> None:
    """Every file a manifest names must exist, and every schema must parse.

    A reference nobody resolves cannot fail: an output shape a package
    describes but does not ship reads as a contract, and a skill body that is a
    mistyped path installs the path as the skill. The database never sees the
    package directory, so this is the last point at which a reference is
    resolvable at all, and every bad one is reported at once.
    """
    refs = [(f"sources[{s['name']}].emits[{e['entity']}]", e["schema"])
            for s in m.get("sources", []) for e in s.get("emits", []) if "schema" in e]
    refs += [(f"agents[{a['name']}].output_schema", a["output_schema"])
             for a in m.get("agents", []) if a.get("output_schema")]
    problems = [f"skills[{s.get('name')}].body -> {s['body'].strip()} does not exist"
                for s in m.get("skills", [])
                if isinstance(s.get("body"), str) and body_path(s["body"]) and not (root / s["body"].strip()).exists()]
    for where, rel in refs:
        f = root / rel
        if not f.exists():
            problems.append(f"{where} -> {rel} does not exist")
            continue
        try:
            json.loads(f.read_text())
        except json.JSONDecodeError as exc:
            problems.append(f"{where} -> {rel} is not valid JSON: {exc}")
    if problems:
        raise PackageError("package %s names files it does not ship:\n  %s"
                           % (m.get("name", root.name), "\n  ".join(problems)))


def load(path: Path) -> tuple[dict[str, Any], Path]:
    """The manifest with every file it points at inlined, and the package root.

    A skill's body and an agent's `output_schema` are FILES in the package and
    COLUMNS in the database, which cannot read the package directory, so they
    become their contents here. Nothing else is mapped: an agent document's
    keys are translated by `agentic.agent_document_to_row`, in the database.
    """
    import yaml

    f = manifest_path(path)
    if not f.exists():
        raise PackageError(f"no manifest at {f}")
    root = f.parent
    m = yaml.safe_load(f.read_text())
    if not isinstance(m, dict):
        raise PackageError(f"{f} is not a manifest: its top level is not a mapping")
    check_refs(root, m)
    for s in m.get("skills", []):
        if isinstance(s.get("body"), str) and body_path(s["body"]):
            s["content"] = (root / s.pop("body").strip()).read_text()
    for a in m.get("agents", []):
        rel = a.pop("output_schema", None)
        if rel and "structured_output_schema" not in a:
            a["structured_output_schema"] = json.loads((root / rel).read_text())
    # Workflows are authored as steps and applied as one YAML document, because
    # define_yaml takes the document.
    for w in m.get("workflows", []):
        if "steps" in w and "yaml" not in w:
            w["yaml"] = yaml.safe_dump({"name": w["name"], "steps": w["steps"]}, sort_keys=False)
            del w["steps"]
    return m, root


# Every schema the storage created, and every schema a manifest entity type
# names: the first catches a schema of functions alone on a first install, the
# second is what a re-apply touches, where `create schema if not exists`
# creates nothing. The extension's own schemas are held by its own checks.
CHECK_SCHEMAS = """
select percolate.check_package_schema(n.nspname)
  from pg_namespace n
 where (n.oid <> all($1::oid[])
        or n.oid in (select c.relnamespace from pg_class c
                      where c.oid = any(array(select to_regclass(t) from unnest($2::text[]) t))))
   and not exists (select 1 from pg_depend dep
                    where dep.classid = 'pg_namespace'::regclass and dep.objid = n.oid
                      and dep.refclassid = 'pg_extension'::regclass and dep.deptype = 'e')
"""


async def apply(conn: Any, m: dict[str, Any], root: Path, owner: uuid.UUID | None) -> Any:
    """Storage, then the manifest, each in one transaction as app_owner.

    STORAGE IS NOT PART OF THE MANIFEST THE DATABASE SEES: a package declares
    entity types over tables, and whatever produces the rows owns the DDL. It
    runs with `percolate.check_package_schema()` in the same transaction, so a
    nullable org_id, a table without RLS or a PUBLIC definer rolls the storage
    back rather than being installed and merely reported.

    TWO TRANSACTIONS, so storage stays if the manifest is then refused; a
    re-apply converges as long as the storage is idempotent DDL (`create ...
    if not exists`), which it has to be anyway for a package to be re-applied.

    THE OWNER is who `rbac.current_user_id()` names while apply_package runs:
    an API source and its runs belong to them, and they get `private` rows
    where an operator install gets `public` ones. The id is a parsed UUID, so
    the claims literal below cannot carry anything else.
    """
    storage = m.pop("storage", None)
    if storage:
        f = root / storage
        if not f.exists():
            raise PackageError(f"manifest names storage {storage}, which is not in the package")
        tables = [e["table"] for e in m.get("entity_types", []) if e.get("table")]
        async with conn.transaction():
            await conn.execute("set local role app_owner")
            before = await conn.fetchval("select coalesce(array_agg(oid), '{}') from pg_namespace")
            await conn.execute(f.read_text())
            await conn.execute(CHECK_SCHEMAS, before, tables)
    async with conn.transaction():
        await conn.execute("set local role app_owner")
        if owner is not None:
            await conn.execute("set local request.jwt.claims = '%s'" % json.dumps({"sub": str(owner)}))
        return await conn.fetchval("select percolate.apply_package($1::jsonb)", json.dumps(m))
