"""Ingestion: an uploaded file becomes chunks, embeddings, or a dataset.

The pipeline is a workflow (`content.install_ingest_workflow()` writes it) and
only its first step is code:

    parse   work    this package, on the `ingest` queue
    embed   work    this package again -- BATCHED, because one request per
                    chunk is the wrong unit and a step output cannot carry
                    more than two vectors (see embed.py)

Importing this module registers the `work` handler. `percolate ingest serve`
is that plus the ordinary step loop.
"""

from .embed import embed_resource, embed_texts
from .handler import OPS, ingest, work
from .policy import ChunkPolicy, IngestPolicy, PolicyError, family_of, resolve

__all__ = [
           "OPS",
           "ChunkPolicy",
           "IngestPolicy",
           "PolicyError",
           "embed_resource",
           "embed_texts",
           "family_of",
           "ingest",
           "resolve",
           "work",
]
