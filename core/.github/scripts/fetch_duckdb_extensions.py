#!/usr/bin/env python3
"""Put the lake's DuckDB extensions where DuckDB loads them from, without running DuckDB (REM-619).

The image build ran `percolate lake doctor --install`, and `install` runs DuckDB. The amd64 image is built on the
ARM runner under QEMU, where DuckDB dies with `qemu: uncaught target signal 11`. On 2026-09-19 that left 0.2.1 on
PyPI with no image. A download writes the same file `install` writes,
~/.duckdb/extensions/v<duckdb>/linux_<arch>/<name>.duckdb_extension, and `load` reads it with autoinstall off.

A build script, not a `percolate` command, so the published package does not change to fix its image. The list is
the package's own `engine.EXTENSIONS`, which does not import DuckDB. The extension repository refuses Python's
default user agent with a 403, so the request names itself.
"""
import gzip
import os
import platform
import urllib.request
from importlib.metadata import version

from percolate_core.lake.engine import EXTENSIONS

arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine().lower()]
duckdb = version("duckdb")
where = os.path.expanduser(f"~/.duckdb/extensions/v{duckdb}/linux_{arch}")
os.makedirs(where, exist_ok=True)
for ext in EXTENSIONS:
    url = f"https://extensions.duckdb.org/v{duckdb}/linux_{arch}/{ext}.duckdb_extension.gz"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "percolate-core"}), timeout=300) as r:
        data = gzip.decompress(r.read())
    with open(os.path.join(where, f"{ext}.duckdb_extension"), "wb") as f:
        f.write(data)
    print(f"{ext}: {len(data)} bytes into {where}")
