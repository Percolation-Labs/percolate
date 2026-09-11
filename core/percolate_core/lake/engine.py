"""A DuckDB connection for the lake, and the sandbox authored SQL runs inside.

TWO CONNECTIONS, NEVER ONE. Authored SQL runs in a SEALED connection: it may
read the input locations Postgres resolved for the run owner, write under the
one prefix Postgres assigned the output, and nothing else. The Iceberg catalog
is attached only in a second connection that never sees authored SQL. A
catalog attached where a tenant's SELECT can reach it is a catalog that answers
that tenant's questions about every other tenant's tables.

WHAT THE SEAL IS, measured on DuckDB 1.5.5 against MinIO (lake.md §3):

    allowed_directories      the resolved inputs + the output prefix
    enable_external_access   false -- no other path, no ATTACH, no INSTALL
    allow_unredacted_secrets false -- duckdb_secrets(redact := false) refused
                                      (set at open, in connect())
    lock_configuration       true  -- none of the above can be SET back

and it is NOT enough by itself: a locked connection still accepts CREATE SECRET,
and a secret scoped to an allowed prefix with an endpoint the tenant controls
turned `COPY … TO 's3://<allowed>/x'` into an upload to the tenant's server.
Hence guard.single_select: authored SQL is one SELECT, classified by DuckDB's
own parser, and every write is this module's.
"""

from __future__ import annotations

import os
import re
import tempfile
from dataclasses import dataclass
from typing import Any

from ..worker.templates import TerminalError

__all__ = ["Lake", "MissingLake", "attach_catalog", "catalog_table", "connect",
           "lake", "q", "qi", "seal", "EXTENSIONS"]

# What a refine step may assume. spatial and iceberg are not optional here:
# lake.md takes geometry and Iceberg as given, so a worker missing either is a
# worker that cannot run the steps written for it, and `lake doctor` says so.
EXTENSIONS = ("httpfs", "parquet", "iceberg", "spatial", "vss")

_DOT_SEGMENT = re.compile(r"(^|/)\.\.?(/|$)")


class MissingLake(TerminalError):
    """duckdb is not installed, or an extension is not."""


def q(value: Any) -> str:
    """A SQL string literal.

    SET, CREATE SECRET and ATTACH do not take bound parameters in DuckDB ("This
    type of statement can't be prepared"), so their values are interpolated --
    and quoted here rather than trusted, because an endpoint or a key with a
    quote in it would otherwise end the statement.
    """
    return "'" + str(value).replace("'", "''") + "'"


def qi(name: str) -> str:
    """A quoted identifier: a column or view name that came from data."""
    return '"' + str(name).replace('"', '""') + '"'


@dataclass(frozen=True)
class Lake:
    """Object storage and, optionally, an Iceberg catalog -- from the environment.

    The SAME variables the Content Server reads (content/storage.py), so a
    deployment configures object storage once. The catalog's credential is a
    NAME (P8_LAKE_CATALOG_TOKEN_REF), resolved here and never stored.
    """
    endpoint: str
    key: str
    secret: str
    region: str
    bucket: str
    catalog_url: str | None
    warehouse: str | None
    catalog_token_ref: str | None

    @property
    def host(self) -> str:
        return self.endpoint.split("://", 1)[-1].rstrip("/")

    @property
    def ssl(self) -> bool:
        return self.endpoint.startswith("https")

    def uri(self, key: str) -> str:
        return f"s3://{self.bucket}/{key}"


def lake() -> Lake | None:
    """The lake this process can reach, or None when no object storage is set.

    None is a real state, not an error: a refine step over inline rows that
    only lands into Postgres needs no object storage at all.
    """
    key, secret = os.environ.get("P8_S3_KEY"), os.environ.get("P8_S3_SECRET")
    if not (key and secret):
        return None
    return Lake(
        endpoint=os.environ.get("P8_S3_ENDPOINT", "http://localhost:9000"),
        key=key, secret=secret,
        region=os.environ.get("P8_S3_REGION", "us-east-1"),
        bucket=os.environ.get("P8_LAKE_BUCKET") or os.environ.get("P8_BUCKET", "p8-content"),
        catalog_url=os.environ.get("P8_LAKE_CATALOG_URL") or None,
        warehouse=os.environ.get("P8_LAKE_WAREHOUSE") or None,
        catalog_token_ref=os.environ.get("P8_LAKE_CATALOG_TOKEN_REF") or None,
    )


def _duckdb():
    try:
        import duckdb
    except ModuleNotFoundError as e:
        raise MissingLake(
            "the lake needs duckdb: pip install 'percolate-core[lake]' "
            f"(missing {e.name})") from None
    return duckdb


def _load(con, ext: str) -> None:
    """Load an extension, installing it only when the process is allowed to.

    The image installs every extension at build time (Dockerfile), because a
    DuckDB extension is a download from extensions.duckdb.org at first use --
    and a worker without egress would otherwise discover its network policy
    inside a customer's step. Installing at run time is for a laptop, and is
    opted into with P8_LAKE_INSTALL_EXTENSIONS=1.
    """
    try:
        con.execute(f"load {ext}")
        return
    except Exception as first:  # noqa: BLE001 -- duckdb raises IOException/CatalogException
        if os.environ.get("P8_LAKE_INSTALL_EXTENSIONS") != "1":
            raise MissingLake(
                f"DuckDB extension {ext!r} is not installed in this image ({first}). "
                "Images built from percolate-core's Dockerfile carry it; on a "
                "laptop, set P8_LAKE_INSTALL_EXTENSIONS=1 to download it once.") from None
    con.execute(f"install {ext}")
    con.execute(f"load {ext}")


def connect(cfg: Lake | None, extensions: tuple[str, ...] = EXTENSIONS):
    """A DuckDB connection with the lake's extensions and S3 secret, unsealed.

    Memory and spill are bounded from the environment, because DuckDB's default
    is 80% of the machine -- which inside a pod is the pod's limit, and the
    OOM kill that follows is the least informative way to learn a query was
    large.
    """
    duckdb = _duckdb()
    tmp = os.environ.get("P8_LAKE_TMP") or os.path.join(tempfile.gettempdir(), "p8-lake")
    os.makedirs(tmp, exist_ok=True)
    # The two secret settings go HERE, at open, and not in seal(): DuckDB
    # refuses "Changing Secret Manager settings after the secret manager is
    # used", and the S3 secret below is its first use. Found by the first
    # end-to-end run, where seal() set them late and every step failed.
    config = {"temp_directory": tmp,
              "memory_limit": os.environ.get("P8_LAKE_MEMORY", "2GB"),
              "autoinstall_known_extensions": False,
              "autoload_known_extensions": False,
              "allow_persistent_secrets": False,
              "allow_unredacted_secrets": False}
    if os.environ.get("P8_LAKE_THREADS"):
        config["threads"] = int(os.environ["P8_LAKE_THREADS"])
    con = duckdb.connect(config=config)
    for ext in extensions:
        _load(con, ext)
    if cfg is not None:
        con.execute(
            "create secret p8_lake (type s3"
            f", key_id {q(cfg.key)}, secret {q(cfg.secret)}"
            f", endpoint {q(cfg.host)}, region {q(cfg.region)}"
            f", use_ssl {'true' if cfg.ssl else 'false'}"
            # Path style: a MinIO on localhost has no per-bucket DNS, and real
            # S3 accepts it too -- one setting rather than a branch.
            ", url_style 'path')")
    return con


def _directory(uri: str) -> str:
    """The directory an allow-list entry names. A glob's directory, and always
    with a trailing slash, so `…/sales` does not also allow `…/sales_private`."""
    if "*" in uri:
        uri = uri[: uri.index("*")]
        uri = uri[: uri.rfind("/") + 1]
    return uri if uri.endswith("/") else uri + "/"


def seal(con, allowed: list[str]) -> list[str]:
    """Confine the connection to `allowed`, irreversibly. Returns the list used.

    A path with a `.` or `..` segment is refused before it reaches the
    allow-list: DuckDB compares strings, so `…/mine/../theirs/` starts with an
    allowed directory, and whether the store then normalises it is the store's
    business (MinIO refused; lake.md §3.2).
    """
    dirs = sorted({_directory(a) for a in allowed})
    for d in dirs:
        if _DOT_SEGMENT.search(d.split("://", 1)[-1]):
            raise TerminalError(f"refusing a lake path with a dot segment: {d}")
    con.execute("set allowed_directories = [" + ", ".join(q(d) for d in dirs) + "]")
    # allow_unredacted_secrets and allow_persistent_secrets are already false:
    # connect() set them at open, the only time DuckDB accepts them.
    con.execute("set enable_external_access = false")
    con.execute("set lock_configuration = true")
    return dirs


# ------------------------------------------------------------------ catalog

def _catalog_headers(cfg: Lake) -> dict[str, str]:
    if not cfg.catalog_token_ref:
        return {}
    from ..core import credential
    return {"Authorization": "Bearer " + credential(cfg.catalog_token_ref)}


def _require_catalog(cfg: Lake | None) -> Lake:
    if cfg is None or not cfg.catalog_url or not cfg.warehouse:
        raise TerminalError(
            "this step reads or writes an Iceberg table and no catalog is configured: "
            "set P8_LAKE_CATALOG_URL (an Iceberg REST catalog, e.g. "
            "http://lakekeeper:8181/catalog) and P8_LAKE_WAREHOUSE on the lake worker")
    return cfg


def catalog_table(cfg: Lake | None, table_ref: str) -> dict[str, str] | None:
    """{location, metadata_location} for a table, or None when it does not exist.

    Asked of the REST catalog directly rather than through an attached DuckDB
    catalog, so that reading an Iceberg input needs no catalog in the sealed
    connection: the sealed side scans the metadata file this returns, from
    inside the table's own location and nowhere else.
    """
    import httpx

    cfg = _require_catalog(cfg)
    ns, _, table = table_ref.partition(".")
    base = cfg.catalog_url.rstrip("/")
    headers = _catalog_headers(cfg)
    with httpx.Client(timeout=30.0) as client:
        conf = client.get(f"{base}/v1/config", params={"warehouse": cfg.warehouse},
                          headers=headers)
        conf.raise_for_status()
        body = conf.json()
        prefix = {**(body.get("defaults") or {}), **(body.get("overrides") or {})}.get("prefix")
        path = f"{base}/v1/{prefix}/namespaces/{ns}/tables/{table}" if prefix else \
               f"{base}/v1/namespaces/{ns}/tables/{table}"
        r = client.get(path, headers=headers)
        if r.status_code == 404:
            return None
        r.raise_for_status()
        t = r.json()
    return {"location": t["metadata"]["location"], "metadata_location": t["metadata-location"]}


def attach_catalog(con, cfg: Lake | None, alias: str = "ice") -> str:
    """Attach the Iceberg catalog to an UNSEALED connection. Never a sealed one.

    `access_delegation_mode 'none'`: data files are read and written with this
    process's own S3 secret rather than credentials the catalog vends, because
    the worker already holds one and a second, catalog-issued credential would
    be a second thing to scope.
    """
    cfg = _require_catalog(cfg)
    auth = "authorization_type 'none'"
    if cfg.catalog_token_ref:
        from ..core import credential
        con.execute(f"create secret p8_catalog (type iceberg, token {q(credential(cfg.catalog_token_ref))})")
        auth = "secret p8_catalog"
    con.execute(f"attach {q(cfg.warehouse)} as {alias} "
                f"(type iceberg, endpoint {q(cfg.catalog_url)}, {auth}, "
                "access_delegation_mode 'none')")
    return alias
