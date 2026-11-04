# Recorded evidence in the core admin UI

This screen belongs to `percolate-core`'s UI, alongside Runs, Query and Walks.
`percolate-application` is a separate product. The `percolate` repository's
`core/` directory is a read-only mirror; edit this repository.

Prepare a local archive with `cases` and `manifest` keys:

```sh
python dev/prepare_evidence_example.py /path/to/fixture.json --out /tmp/core-evidence
P8_UI_EVIDENCE_EXAMPLE=/tmp/core-evidence percolate ui serve --host 127.0.0.1 --port 8082
```

Open `http://localhost:8082/#/evidence`. The optional preparation step needs npm;
it bundles a pinned DuckDB browser engine and worker locally. No database, runtime
CDN, new credential, or provider call is involved. The server serves only four
named example assets, only to loopback clients, and only when explicitly enabled.
The archive and generated files stay outside the package. Ordinary UI sign-in
and PostgREST reads retain their existing behavior.

`node dev/check-evidence.cjs` checks the configured server (or `P8_UI_TEST_URL`).
It verifies the E9b results, filtering, exact decision text and reader reasons,
editable SQL, query-error recovery, and 390px/320px layouts. Run the related unit
checks with `python -m unittest discover -s tests -p 'test_ui_*.py'`.

The example is recorded evidence, not a live agent feed or human confirmation.
The view closes its query worker when navigating away. Live evidence storage and
shared selection are separate work.
