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

from .refusal import refusal

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
    except Exception as exc:  # asyncpg errors, matched by name to avoid the import
        # The work moved into rbac.bootstrap_admin(), which arrived in extension
        # 0.1.2 -- so this command, pointed at an older database, now fails on a
        # function that is not there. Said plainly, because the raw
        # UndefinedFunctionError traceback reads as a broken CLI rather than as
        # a database that predates it.
        if type(exc).__name__ == "UndefinedFunctionError":
            typer.secho(
                "error: this database does not have rbac.bootstrap_admin(), which "
                "arrived in the percolate extension 0.1.2.", fg="red", err=True)
            typer.secho(
                "hint:  upgrade it first -- `set role app_owner; "
                "alter extension percolate update;` -- or use a percolate-core "
                "before 0.1.7, which did the inserts itself.", err=True)
            raise typer.Exit(1) from None
        # A REFUSAL IS ALSO A DESIGNED ANSWER, and this arm used to miss it:
        # matching `RaiseError` matches SQLSTATE P0001 only, so a database that
        # refuses the DSN's role -- "permission denied for function
        # bootstrap_admin", 42501 -- got the traceback this arm exists to
        # avoid. core/refusal.py is the same rule the HTTP surfaces use.
        if type(exc).__name__ != "RaiseError" and refusal(exc) is None:
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
        # AND THE DATABASE, which this did not check at all. --dry-run answers
        # "what would this need", and a run needs a reachable owner DSN before
        # it needs anything the lines above report -- so a reader could be told
        # "credentials: all present", run it for real, and be stopped by
        # `no DSN` on the very next command. Walking the install guide, that
        # was the third prerequisite discovered one error at a time.
        #
        # Reported rather than raised, like the credentials above it, because a
        # --dry-run that exits on the first missing thing withholds the rest of
        # the answer -- which is the behaviour that made this worth fixing.
        chosen = dsn or os.environ.get("P8_ADMIN_DSN") or os.environ.get("P8_DSN")
        if not chosen:
            typer.echo(
                "  database:    NO DSN -- pass --dsn, or set P8_ADMIN_DSN (or P8_DSN).\n"
                "               On the compose stack that is\n"
                "               postgres://p8:p8@localhost:5432/percolate"
            )
        else:
            # Connecting is not writing, and an unreachable-or-wrong DSN is the
            # next stop after a missing one. Checking it here is the difference
            # between "the environment is ready" and "the environment has the
            # variable set".
            async def _probe() -> str | None:
                try:
                    conn = await _connect(chosen)
                except Exception as err:  # asyncpg raises many shapes
                    return str(err)
                try:
                    await conn.fetchval("select 1 from rbac.users limit 1")
                except Exception as err:
                    return f"connected, but cannot read rbac.users ({err})"
                finally:
                    await conn.close()
                return None

            problem = asyncio.run(_probe())
            typer.echo(
                "  database:    reachable, and can read rbac.*" if problem is None
                else f"  database:    UNUSABLE -- {problem}"
            )
        return

    if missing and wants_documents:
        typer.secho(
            f"{manifest['name']} needs {', '.join(missing)} in this process's environment.\n"
            "  The corpus is embedded by the real pipeline rather than shipped as\n"
            "  literal vectors, so loading it costs one embedding call per chunk.\n"
            "  The stack's ingest worker makes that call, so it needs the key too:\n"
            "  on compose, set it where `docker compose up` runs (its shell or the\n"
            "  .env beside docker-compose.yml) before the stack starts.\n"
            "  Set the key, or pass --skip-documents to load everything else.",
            fg=typer.colors.RED,
            err=True,
        )
        raise typer.Exit(1)

    # THE SIGNING SECRET, CHECKED HERE RATHER THAN AT THE UPLOAD.
    #
    # The fourth prerequisite discovered one error at a time, and the most
    # expensive of them, because it is the only one that failed AFTER writing:
    # `_jwt_secret` is not reached until the documents step, so a load with no
    # P8_JWT_SECRET ran tenants.sql, schema.sql, the sources, the graph, the
    # plugin and the workflows -- reporting each one -- and then stopped on
    # `no signing secret`. Everything before it had landed, so the obvious
    # response is to set the secret and re-run, which is the path that used to
    # duplicate the corpus.
    #
    # Same shape as the credentials gate above: everything a documents step
    # needs is checked before the first write, so "this will not work" is
    # something you learn in the first second rather than the last.
    if wants_documents and not token and not (secret or os.environ.get("P8_JWT_SECRET")):
        typer.secho(
            f"{manifest['name']} needs a signing secret to upload its documents.\n"
            "  Pass --secret or set P8_JWT_SECRET, and it has to be the SAME secret\n"
            "  the stack verifies with -- PGRST_JWT_SECRET for PostgREST and\n"
            "  P8_JWT_SECRET for the services -- or the token will verify nowhere.\n"
            "  On a compose stack brought up with no .env, that is\n"
            "  change-me-a-long-random-string-at-least-32-chars\n"
            "  Or pass --skip-documents to load everything else.",
            fg=typer.colors.RED,
            err=True,
        )
        raise typer.Exit(1)

    target_dsn = _admin_dsn(dsn)
    upload_token = token
    if wants_documents and not upload_token and as_email:
        upload_token = None  # minted below, once we know the user id

    async def _run() -> None:
        nonlocal upload_token, stalled, still_ingesting
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

            # BEFORE THE FIRST WRITE, and it needs the connection -- which is
            # why it is here rather than in `read_manifest` with the rest of the
            # pre-flight. An extension older than the document translation
            # (REM-70) accepts an agent written as a schema document and stores
            # it with an empty prompt, reporting success; a refusal discovered at
            # the plugin step would leave the schema, the entities and the graph
            # already written.
            await samples.assert_can_load(conn, root, manifest)

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
                        # AND MEMBERSHIP, WHICH THE CLAIM ALONE IS NOT.
                        #
                        # `rbac.current_org_ids()` INTERSECTS the `orgs` claim
                        # with real `rbac.org_members` rows, deliberately: a
                        # token asserting an org nobody is in must resolve to
                        # nothing, or the claim would be the whole of tenancy.
                        # Minting the claims was therefore necessary and not
                        # sufficient. `bootstrap_admin` puts the new admin in no
                        # org at all, and this sample enrols only its own
                        # `harbour-reader`, so the documented command on a fresh
                        # install -- `sample load ... --as-email you@example.com`
                        # -- uploaded the three shared documents and then died on
                        # the first org-scoped one with `not authorized to
                        # register content for that organization`, having already
                        # written the schema, entities, graph, plugin and
                        # workflow. A half-loaded sample and a message about
                        # authorization.
                        #
                        # Scoped as narrowly as the fix allows: the loading user
                        # only, into orgs THIS SAMPLE'S OWN index names -- rows
                        # it created itself moments earlier in the same run. Not
                        # the thing tenants.sql argues against, which is a demo
                        # enrolling every user in the database into its tenants.
                        if orgs:
                            await conn.execute(
                                """
                                insert into rbac.org_members (org_id, user_id, role)
                                select o.id, $1::uuid, 'admin' from rbac.orgs o
                                 where o.id::text = any($2::text[])
                                    or o.slug = any($2::text[])
                                on conflict (org_id, user_id) do nothing
                                """,
                                uid, orgs,
                            )
                        upload_token = mint_jwt(
                            uid, signing, ttl_seconds=900,
                            extra={"orgs": orgs} if orgs else None,
                        )
                        if orgs:
                            typer.echo(
                                f"  upload token covers {len(orgs)} org(s), "
                                f"and {as_email} is a member of each"
                            )
                    done, pending = await _upload_documents(
                        conn, where, content_url, upload_token, yaml)
                    for line in done:
                        typer.echo(f"  {line}")
                    stalled, finished = await _first_embed_verdict(conn, pending)
                    still_ingesting = 0 if finished else len(pending)
                    continue
                for line in done:
                    typer.echo(f"  {line}")
        finally:
            await conn.close()

    stalled: str | None = None
    still_ingesting = 0
    try:
        asyncio.run(_run())
    except samples.SampleError as err:
        typer.secho(str(err), fg=typer.colors.RED, err=True)
        raise typer.Exit(1)

    typer.echo("")
    if stalled:
        # THE KEY THE CHECK ABOVE ASKED FOR IS NOT THE KEY THAT EMBEDS. This
        # process only uploads; the ingest worker makes the embedding call, and
        # it reads LLM_API_KEY from ITS OWN environment -- on compose, the
        # shell or .env that `docker compose up` ran from. A key exported after
        # the stack came up passed the gate above and embedded nothing: every
        # embed task retried on `credential_ref 'LLM_API_KEY' is not set` and
        # failed for good while this command printed "loaded". Reported here,
        # from the first failed attempt, rather than left for a SEARCH that
        # returns nothing.
        typer.secho(f"loaded, but the corpus is not embedding: {stalled}", fg=typer.colors.RED, err=True)
        typer.secho(
            "  The ingest worker makes that call and reads the key from its own\n"
            "  environment. On compose, restart it with the key set:\n"
            "    LLM_API_KEY=sk-... docker compose up -d\n"
            "  (or put it in the .env beside docker-compose.yml), then run this\n"
            "  command again -- it replaces documents whose ingestion failed.",
            err=True,
        )
        raise typer.Exit(1)
    if skip_documents:
        # No documents were posted, so nothing is queued on `ingest` and the
        # embed-watch below would show an empty result forever. Point at the
        # thing that is actually loaded instead.
        typer.echo("loaded (documents skipped). Load the corpus later with the same "
                   "command and no --skip-documents, once LLM_API_KEY is set.")
    elif not wants_documents:
        typer.echo("loaded.")
    elif not still_ingesting:
        typer.echo("loaded, and every document is embedded.")
    else:
        typer.echo("loaded. The corpus embeds asynchronously -- watch it with:")
        typer.echo("  select step_key, status, attempts from workflow.tasks where queue = 'ingest';")


def _token_subject(token: str) -> str | None:
    """The `sub` of a token, read without verifying it.

    Used only to find the rows this same caller uploaded on an earlier run, and
    the Content Server verifies the token properly on every upload.
    """
    import base64
    import json

    try:
        body = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))).get("sub")
    except (IndexError, ValueError):
        return None


async def _earlier_uploads(conn: Any, owner: str, channel: str, title: str) -> list[Any]:
    """What an earlier run of this load left for one document.

    Matched on the uploader, the channel and the title, so nothing another
    user uploaded can match. Not on the org: a title is unique within a
    sample's index, and a document whose `org:` was edited is exactly the
    earlier version a re-run should replace.
    """
    return await conn.fetch(
        """
        select r.id::text as id, f.checksum, w.status as ingest
          from content.resources r
          join content.channels c on c.id = r.channel_id
          left join content.files f on f.id = r.file_id
          left join workflow.runs w on w.external_id = 'ingest:' || r.id::text
         where r.owner_id = $1::uuid and c.name = $2 and r.title = $3
        """,
        owner, channel, title,
    )


async def _upload_documents(conn: Any, where: Any, content_url: str, token: str,
                            yaml: Any) -> tuple[list[str], list[str]]:
    """POST each document to the Content Server, as any uploader would.

    Through the real endpoint rather than an INSERT, because that is the whole
    claim being demonstrated: a file arrives and becomes chunks, vectors and
    graph nodes with nothing else run by hand. An INSERT into
    content.resource_chunks would skip precisely the part worth showing.

    A SECOND RUN REPLACES WHAT DID NOT WORK AND LEAVES WHAT DID. Every run used
    to post every document again, and an upload is a new resource every time,
    so a re-run -- the documented way to pick up an edit, and the obvious
    response to a load whose embeddings failed for want of a key -- either
    duplicated the corpus or, on an extension that keyed documents by title,
    failed every parse on `idx_node_keys_canonical`. The rows this caller
    uploaded before are therefore looked up first: identical bytes whose
    ingestion is running or finished are kept, and anything else under the
    same title -- a failed ingest, an older version, a duplicate from an
    earlier run -- is deleted before the upload that replaces it.

    Returns the lines to print and the ids of the resources whose ingestion is
    still to finish: everything it uploaded, and anything it kept mid-retry.
    """
    import hashlib

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

    owner = _token_subject(token)
    done: list[str] = []
    pending: list[str] = []
    async with httpx.AsyncClient(timeout=60) as client:
        # WAIT FOR THE CONTENT SERVER, then post. Run straight after
        # `docker compose up`, the published port accepts a connection before
        # uvicorn is listening behind it, and the first upload died on
        # `ReadError` after every earlier step had written. Probing /health
        # rather than retrying the POST, because a POST that failed mid-read
        # may already have registered the document.
        base = content_url.rstrip("/")
        for _ in range(30):
            try:
                if (await client.get(f"{base}/health", timeout=5)).status_code == 200:
                    break
            except httpx.TransportError:
                pass
            await asyncio.sleep(2)
        else:
            raise samples.SampleError(
                f"the Content Server at {base} did not answer /health for a minute "
                "-- is the stack up, and is --content-url its published port?")
        for e in entries:
            body = (where / e["file"]).read_bytes()
            title = e.get("title", e["file"])
            earlier = await _earlier_uploads(
                conn, owner, e.get("channel", "uploads"), title) if owner else []
            checksum = hashlib.sha256(body).hexdigest()
            keep = next((r for r in earlier if r["checksum"] == checksum
                         and r["ingest"] in ("running", "succeeded")), None)
            stale = [r["id"] for r in earlier if r is not keep]
            if stale:
                # As app_owner, which this connection already is: the loader
                # removes only rows it uploaded, and their chunks cascade.
                await conn.execute(
                    "delete from content.resources where id = any($1::uuid[])", stale)
            if keep is not None:
                done.append(f"unchanged {e['file']} -> {keep['id']}"
                            + (f" (removed {len(stale)} stale)" if stale else ""))
                if keep["ingest"] == "running":
                    # Still retrying, possibly on the very key this run is
                    # about to report missing -- so it is watched like an
                    # upload rather than counted as done.
                    pending.append(keep["id"])
                continue
            headers = {
                "Authorization": f"Bearer {token}",
                "Content-Type": e.get("content_type", "text/markdown"),
                "x-p8-title": title,
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
            resource_id = r.json().get("resource_id")
            pending.append(resource_id)
            done.append(f"uploaded {e['file']} -> {resource_id}"
                        + (f" (replaced {len(stale)})" if stale else ""))
    return done, pending


async def _first_embed_verdict(conn: Any, resource_ids: list[str],
                               wait_seconds: float = 20.0) -> tuple[str | None, bool]:
    """Wait briefly for these uploads to embed, or for the first credential error.

    Returns (error, finished): the error text when an embed task has already
    failed on a missing credential, and whether every embed task succeeded
    within `wait_seconds`. Neither is a timeout's business -- the load has done
    its part by then, and ingestion is asynchronous by design. Only a
    credential error is reported, because it is the one failure that retrying
    cannot fix and a fresh stack produces by default.
    """
    if not resource_ids:
        return None, True
    runs = [f"ingest:{i}" for i in resource_ids]
    deadline = asyncio.get_running_loop().time() + wait_seconds
    while True:
        rows = await conn.fetch(
            """
            select t.status, t.error::text as error
              from workflow.tasks t join workflow.runs w on w.id = t.run_id
             where w.external_id = any($1::text[]) and t.step_key = 'embed'
            """,
            runs,
        )
        for row in rows:
            if row["error"] and "credential_ref" in row["error"]:
                import json

                try:
                    return json.loads(row["error"]).get("error", row["error"]), False
                except ValueError:
                    return row["error"], False
        if rows and all(r["status"] == "succeeded" for r in rows):
            return None, True
        if asyncio.get_running_loop().time() > deadline:
            return None, False
        await asyncio.sleep(1.0)
