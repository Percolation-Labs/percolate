"""`percolate auth` and `percolate sample` -- what stands between a fresh
database and a working request.

A new install has no users, no roles and no permissions, and that is correct:
the alternative is a default administrator with a password that is in a public
compose file. But it means every documented `curl` fails until somebody makes
the first administrator and signs a token, and neither is something a reader
should have to write from a JWT spec.

So these two exist, and they are deliberately NOT part of any service. Nothing
here runs on a schedule or answers a port; `bootstrap` is a thing you do once,
with credentials you would not give a service, and `token` is a thing you do
whenever you want to make a request by hand.

    percolate auth bootstrap --email me@example.com --password ... --print-token
    percolate auth token --email me@example.com

`auth` needs base install only -- asyncpg and typer -- so it works in a
worker-only deployment, which is where somebody is most likely to be holding
admin credentials and no other tooling. `sample` additionally reads YAML.

`percolate sample load` is the other half: an empty database and a working
token still answer every documented query with zero rows. See `samples.py` for
why a sample is a directory of authored documents rather than a SQL dump.
"""

from __future__ import annotations

import asyncio
import os
from typing import Any

import typer

app = typer.Typer(help="Bootstrap the first identity, and sign tokens.", no_args_is_help=True)


# The permission list used to live here, as a Python constant, and it was
# WRONG -- ("workflow_runs", "read") and ("workflow_runs", "write") where every
# RLS policy in the collection asks for "select". `role_permissions.action` is
# free text compared with `=`, so none of that was an error anywhere: the rows
# inserted, the role looked populated, and `workflow.runs_api` then returned
# zero rows to the administrator this command had just created -- which is
# indistinguishable from a workflow that never ran.
#
# It is not a corrected list now, it is no list. `rbac.bootstrap_admin()` in
# the extension holds the vocabulary next to the policies that define it, and
# this command calls that. A copy over here could only ever be right until the
# schema moved, and nothing would report the day it stopped being.


def _admin_dsn(dsn: str | None) -> str:
    """The DSN to bootstrap with, which is not the one a service uses.

    Creating the first role grant means writing `rbac.user_roles` directly, and
    no service role can: they hold no table grants at all, which is the
    property that makes "a compromised service can do what its caller could"
    true. So this asks for an owner-level DSN and says so, rather than failing
    later with a permission error that reads like a bug.
    """
    chosen = dsn or os.environ.get("P8_ADMIN_DSN") or os.environ.get("P8_DSN")
    if not chosen:
        raise typer.BadParameter(
            "no DSN. Pass --dsn, or set P8_ADMIN_DSN (or P8_DSN).\n"
            "  It must be able to write rbac.* -- the database owner, not the "
            "worker or authenticator role a service connects as.\n"
            "  On the compose stack that is "
            "postgres://p8:p8@localhost:5432/percolate."
        )
    return chosen


def _jwt_secret(secret: str | None) -> str:
    chosen = secret or os.environ.get("P8_JWT_SECRET")
    if not chosen:
        raise typer.BadParameter(
            "no signing secret. Pass --secret or set P8_JWT_SECRET.\n"
            "  It has to be the SAME secret the stack verifies with -- "
            "PGRST_JWT_SECRET for PostgREST and P8_JWT_SECRET for the "
            "services -- or the token will verify nowhere."
        )
    return chosen


async def _connect(dsn: str) -> Any:
    import asyncpg

    return await asyncpg.connect(dsn)


@app.command()
def bootstrap(
    email: str = typer.Option(..., help="The first user's email."),
    password: str = typer.Option(..., help="Their password."),
    role: str = typer.Option("admin", help="Role name to create and grant."),
    dsn: str | None = typer.Option(None, help="Owner-level DSN. Default: P8_ADMIN_DSN, then P8_DSN."),
    print_token: bool = typer.Option(False, "--print-token", help="Also sign a token for them."),
    orgs: str | None = typer.Option(None, help="Comma-separated org ids for the printed token's `orgs` claim."),
    ttl: int = typer.Option(3600, help="Token lifetime in seconds, with --print-token."),
    secret: str | None = typer.Option(None, help="Signing secret. Default: P8_JWT_SECRET."),
) -> None:
    """Create the first user, a role, and the grant between them.

    Idempotent: run it twice and the second run reports the same user id rather
    than failing, so it is safe in a provisioning script that reruns.

    The work is done by `rbac.bootstrap_admin()` in the extension rather than
    by statements here, so the permission vocabulary lives next to the policies
    that consult it and cannot drift away from them -- which it had.

    That function is not `rbac.grant_role`, and the difference is not an
    oversight to tidy up later. `grant_role` is gated on `users/admin`, and on
    an empty database nobody holds it -- including the person bootstrapping. A
    function that granted the first admin to whoever asked first would be a
    hole, so `bootstrap_admin` refuses once any role has been granted to
    anyone, and a bootstrap step that needs owner credentials is the honest
    shape.
    """
    from .identity import mint_jwt

    target = _admin_dsn(dsn)
    signing = _jwt_secret(secret) if print_token else None

    async def _run() -> None:
        conn = await _connect(target)
        try:
            async with conn.transaction():
                existing = await conn.fetchval(
                    "select id from rbac.users where email = $1", email
                )
                uid = await conn.fetchval(
                    "select rbac.bootstrap_admin($1, $2, $3)", email, password, role
                )
                typer.echo(
                    f"user     {email} -> {uid}" + (" (existed)" if existing else "")
                )
                granted = await conn.fetchval(
                    "select count(*) from rbac.role_permissions where role = $1", role
                )
                typer.echo(f"role     {role} with {granted} permissions, granted")
        finally:
            await conn.close()

        if signing:
            extra = {"orgs": [o.strip() for o in orgs.split(",") if o.strip()]} if orgs else None
            typer.echo("")
            typer.echo(mint_jwt(str(uid), signing, ttl_seconds=ttl, extra=extra))

    # A second administrator is REFUSED by rbac.bootstrap_admin, and that is a
    # designed answer rather than a crash -- so it exits like one. Unhandled,
    # asyncpg's RaiseError reaches typer's traceback renderer and the person
    # reading it sees thirty lines of asyncio frames with the one sentence that
    # matters ("rbac is already bootstrapped") somewhere in the middle.
    try:
        asyncio.run(_run())
    except Exception as exc:  # asyncpg.exceptions.RaiseError, without the import
        if type(exc).__name__ != "RaiseError":
            raise
        # .message, not str(exc): asyncpg's __str__ already appends "HINT: ..."
        # to the message, so formatting the hint as well printed it twice.
        typer.secho(f"error: {getattr(exc, 'message', exc)}", fg="red", err=True)
        hint = getattr(exc, "hint", None)
        if hint:
            typer.secho(f"hint:  {hint}", err=True)
        raise typer.Exit(1) from None


@app.command()
def token(
    email: str | None = typer.Option(None, help="Look the subject up by email."),
    sub: str | None = typer.Option(None, help="Or give the user id directly."),
    role: str = typer.Option("authenticated", help="Postgres role claim, which PostgREST switches to."),
    orgs: str | None = typer.Option(None, help="Comma-separated org ids for the `orgs` claim."),
    ttl: int = typer.Option(3600, help="Lifetime in seconds."),
    dsn: str | None = typer.Option(None, help="Only needed with --email."),
    secret: str | None = typer.Option(None, help="Signing secret. Default: P8_JWT_SECRET."),
) -> None:
    """Sign a bearer token for an existing user.

    `--sub` needs no database at all, which matters: signing is an operation on
    a secret, not on the data, and a deployment that mints tokens from its own
    auth provider should be able to do it with nothing of ours running.

    `--orgs` IS THE ONE PEOPLE MISS. Tenanted rows carry an org_id and the
    policies filter on the `orgs` claim, so a token without it sees only the
    shared tier -- rows with a null org. That is not an error and does not look
    like one: queries return zero rows and `LOOKUP` reports the name
    unresolved, which reads as "the data did not load" rather than "you are not
    in that tenant". If a sample or an import put data in an org, name it here.
    """
    from .identity import mint_jwt

    if not (email or sub):
        raise typer.BadParameter("give --email or --sub")
    signing = _jwt_secret(secret)

    resolved = sub
    if resolved is None:
        target = _admin_dsn(dsn)

        async def _lookup() -> str | None:
            conn = await _connect(target)
            try:
                return await conn.fetchval(
                    "select id::text from rbac.users where email = $1", email
                )
            finally:
                await conn.close()

        resolved = asyncio.run(_lookup())
        if resolved is None:
            typer.secho(
                f"no user with email {email!r} -- run `percolate auth bootstrap` first",
                fg=typer.colors.RED,
                err=True,
            )
            raise typer.Exit(1)

    extra = {"orgs": [o.strip() for o in orgs.split(",") if o.strip()]} if orgs else None
    typer.echo(mint_jwt(resolved, signing, role=role, ttl_seconds=ttl, extra=extra))


# ---------------------------------------------------------------------------
# `percolate sample` -- load a directory of documents into an empty install.
# ---------------------------------------------------------------------------

sample_app = typer.Typer(help="Load a sample dataset.", no_args_is_help=True)


@sample_app.command("load")
def sample_load(
    path: str = typer.Argument(..., help="The sample directory (holds manifest.yaml)."),
    dsn: str | None = typer.Option(None, help="Owner-level DSN. Default: P8_ADMIN_DSN, then P8_DSN."),
    content_url: str = typer.Option("http://localhost:8081", help="Content Server, for the documents step."),
    token: str | None = typer.Option(None, help="Bearer token for uploads. Default: minted from --as-email."),
    as_email: str | None = typer.Option(None, help="Mint an upload token for this user."),
    secret: str | None = typer.Option(None, help="Signing secret. Default: P8_JWT_SECRET."),
    skip_documents: bool = typer.Option(False, "--skip-documents", help="Everything but the corpus."),
    dry_run: bool = typer.Option(False, "--dry-run", help="Check the manifest and the environment, write nothing."),
) -> None:
    """Apply a sample, in the order its manifest declares.

    Idempotent throughout, so a second run is how you pick up an edit rather
    than something to avoid.

    The documents step needs a **real embedding key**, and the manifest says
    which environment variable holds it. That is deliberate: the corpus is
    uploaded and embedded by the running pipeline rather than shipped as
    literal vectors, so what you search is what a model produced. `--dry-run`
    reports a missing key without writing anything; `--skip-documents` loads
    everything else and leaves retrieval for when you have one.
    """
    from pathlib import Path

    from . import samples
    from .identity import mint_jwt

    root = Path(path)
    try:
        manifest = samples.read_manifest(root)
    except samples.SampleError as err:
        typer.secho(str(err), fg=typer.colors.RED, err=True)
        raise typer.Exit(1)

    missing = samples.missing_credentials(manifest, dict(os.environ))
    wants_documents = any("documents" in s for s in manifest["load"]) and not skip_documents

    typer.echo(f"{manifest['name']} {manifest.get('version', '')}".rstrip())
    if dry_run:
        # Reported, not raised. --dry-run exists to answer "what would this
        # need", so exiting on the missing key would withhold the answer.
        for step in manifest["load"]:
            kind, target = next(iter(step.items()))
            skipped = " (skipped)" if kind == "documents" and skip_documents else ""
            typer.echo(f"  would apply {kind:<10} {target}{skipped}")
        typer.echo(
            "  credentials: " + ("all present" if not missing
                                 else f"MISSING {', '.join(missing)}"
                                      + (" -- needed by the documents step" if wants_documents
                                         else " -- not needed, documents are skipped"))
        )
        return

    if missing and wants_documents:
        typer.secho(
            f"{manifest['name']} needs {', '.join(missing)} in this process's environment.\n"
            "  The corpus is embedded by the real pipeline rather than shipped as\n"
            "  literal vectors, so loading it costs one embedding call per chunk.\n"
            "  Set the key, or pass --skip-documents to load everything else.",
            fg=typer.colors.RED,
            err=True,
        )
        raise typer.Exit(1)

    target_dsn = _admin_dsn(dsn)
    upload_token = token
    if wants_documents and not upload_token and as_email:
        upload_token = None  # minted below, once we know the user id

    async def _run() -> None:
        nonlocal upload_token
        yaml = samples._yaml()
        conn = await _connect(target_dsn)
        try:
            # EVERYTHING A SAMPLE CREATES IS OWNED BY app_owner, like the rest
            # of the collection. Loading as the superuser you connected with
            # produces objects it owns, and the consequence is not cosmetic:
            # `register_embedding_space` creates the vector table, and one
            # owned by the superuser cannot be written by the SECURITY DEFINER
            # function that runs as app_owner -- every embed task then fails
            # with `must be owner of table emb_...`, long after the load
            # reported success. Every other table in the collection is
            # app_owner's for the RLS reason; this keeps a sample from being
            # the exception.
            #
            # `session_user` is unchanged by SET ROLE, which is what
            # `agentic.may_author` reads, so apply_plugin still takes the
            # migration path.
            try:
                await conn.execute("set role app_owner")
            except Exception as err:
                raise samples.SampleError(
                    f"cannot `set role app_owner` ({err}). A sample is loaded as "
                    "the schema owner; connect with a DSN that is a member of "
                    "app_owner -- the database owner, not a service role."
                ) from err

            for step in manifest["load"]:
                kind, target = next(iter(step.items()))
                where = root / target
                if kind == "sql":
                    # `reset role` after, because a sample's schema file
                    # legitimately does `set role app_owner` -- ownership is
                    # part of what it is setting up -- and that would otherwise
                    # persist on this connection through every later step.
                    await conn.execute(where.read_text())
                    # Back to app_owner, NOT `reset role`: a schema file
                    # legitimately sets its own, and resetting would hand the
                    # remaining steps back to the superuser.
                    await conn.execute("set role app_owner")
                    done = [f"sql {target}"]
                elif kind == "sources":
                    done = await samples.apply_sources(conn, yaml.safe_load(where.read_text()))
                elif kind == "graph":
                    done = await samples.apply_graph(conn, yaml.safe_load(where.read_text()))
                elif kind == "plugin":
                    done = await samples.apply_plugin(conn, yaml.safe_load(where.read_text()))
                elif kind == "workflows":
                    done = await samples.apply_workflows(conn, list(where.glob("*.yaml")))
                elif kind == "documents":
                    if skip_documents:
                        typer.echo("  documents  skipped")
                        continue
                    if not upload_token:
                        signing = _jwt_secret(secret)
                        uid = await conn.fetchval(
                            "select id::text from rbac.users where email = $1", as_email
                        ) if as_email else None
                        if uid is None:
                            raise samples.SampleError(
                                "uploading needs a token: pass --token, or --as-email "
                                "for a user that exists (percolate auth bootstrap makes one)"
                            )
                        # The token carries every org the index names. A sample
                        # that demonstrates tenancy has to WRITE into more than
                        # one tenant, and the Content Server refuses an upload
                        # for an organization the caller's claims do not cover
                        # -- "not authorized to register content for that
                        # organization", which is the check working. Loading is
                        # an administrative act done with the signing secret in
                        # hand, so this mints the claims it needs and lets them
                        # expire in fifteen minutes.
                        orgs = samples.orgs_in_documents(where, samples._yaml())
                        upload_token = mint_jwt(
                            uid, signing, ttl_seconds=900,
                            extra={"orgs": orgs} if orgs else None,
                        )
                        if orgs:
                            typer.echo(f"  upload token covers {len(orgs)} org(s)")
                    done = await _upload_documents(where, content_url, upload_token, yaml)
                for line in done:
                    typer.echo(f"  {line}")
        finally:
            await conn.close()

    try:
        asyncio.run(_run())
    except samples.SampleError as err:
        typer.secho(str(err), fg=typer.colors.RED, err=True)
        raise typer.Exit(1)

    typer.echo("")
    typer.echo("loaded. The corpus embeds asynchronously -- watch it with:")
    typer.echo("  select step_key, status, attempts from workflow.tasks where queue = 'ingest';")


async def _upload_documents(where: Any, content_url: str, token: str, yaml: Any) -> list[str]:
    """POST each document to the Content Server, as any uploader would.

    Through the real endpoint rather than an INSERT, because that is the whole
    claim being demonstrated: a file arrives and becomes chunks, vectors and
    graph nodes with nothing else run by hand. An INSERT into
    content.resource_chunks would skip precisely the part worth showing.
    """
    import httpx

    # Imported here as well as in the caller: this function reaches for
    # SampleError only on the failure path, so a missing import survives every
    # successful run and then turns the first real upload failure into
    # `NameError: name 'samples' is not defined` -- losing the status code and
    # body that said what actually went wrong.
    from . import samples

    index_path = where / "index.yaml"
    entries = yaml.safe_load(index_path.read_text()) if index_path.exists() else None
    if entries is None:
        entries = [{"file": p.name, "title": p.stem} for p in sorted(where.glob("*.md"))]

    done = []
    async with httpx.AsyncClient(timeout=60) as client:
        for e in entries:
            body = (where / e["file"]).read_bytes()
            headers = {
                "Authorization": f"Bearer {token}",
                "Content-Type": e.get("content_type", "text/markdown"),
                "x-p8-title": e.get("title", e["file"]),
            }
            if e.get("channel"):
                headers["x-p8-channel"] = e["channel"]
            if e.get("org"):
                headers["x-p8-org"] = e["org"]
            r = await client.post(f"{content_url.rstrip('/')}/files", content=body, headers=headers)
            if r.status_code >= 300:
                raise samples.SampleError(
                    f"uploading {e['file']} failed: HTTP {r.status_code} {r.text[:200]}"
                )
            done.append(f"uploaded {e['file']} -> {r.json().get('resource_id')}")
    return done
