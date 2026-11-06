settle embed_sources
psql "$P8_DSN" -c "select source, rows_total, missing from aiq.source_embedding_status()"
