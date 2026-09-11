"""The lake: refinement after staging, in DuckDB, where the bytes already are.

Staging holds what a source told us; the three targets hold what we believe
(specs/world-model-ingestion/sources.md §2-3). Between them is the work of
cleaning, joining, deduplicating, locating and embedding -- and doing it by
pulling every staged record into Postgres first is what puts a whole feed's
worth of rows through the database to keep a few hundred of them.

This subpackage does that work in a DuckDB process beside object storage and
sends Postgres only what is worth keeping: a registered dataset (Parquet or
Iceberg), a bounded number of landed rows, or both. lake.md is the argument;
lake.sql is the half the database holds.

    percolate lake serve --queue lake
    percolate lake doctor

Needs the `lake` extra and object storage configured the way the Content Server
is (P8_S3_ENDPOINT / P8_S3_KEY / P8_S3_SECRET). Without object storage a
refine step still runs over inline rows and can land them; it cannot read or
write a dataset, and says so by name.
"""
