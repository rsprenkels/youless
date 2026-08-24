-- perf-004: enable columnar compression on the pi4 replica.
--
-- Same settings as patricia (perf-001), which measured 11.5x on the identical
-- data shape and made historical queries 15-30% FASTER, because the I/O saved
-- outweighs the decompression cost on a Pi.
--
-- pi4 state before this runs: 3,337,217 rows, 16 chunks, 508 MB, freshly
-- synced. Chunk interval is 30 days here, so compress_after of 14 days leaves
-- the newest chunk alone.
--
-- Run against pi4:
--   psql -h pi4 -U tsdb -d timescale -f perf-004-replica-compression.sql
--
-- Rollback:
--   SELECT remove_compression_policy('data');
--   SELECT decompress_chunk(show_chunks, if_compressed => true) FROM show_chunks('data');
--   ALTER TABLE data SET (timescaledb.compress = false);

\timing on

-- segmentby is empty because this is a single meter. If uid ever holds more
-- than one device, segment by it instead.
ALTER TABLE data SET (timescaledb.compress,
                      timescaledb.compress_orderby   = 'tm DESC',
                      timescaledb.compress_segmentby = '');

SELECT add_compression_policy('data', INTERVAL '14 days', if_not_exists => true);

-- Compress the existing backlog now rather than waiting for the policy.
SELECT compress_chunk(show_chunks, if_not_compressed => true)
FROM show_chunks('data', older_than => INTERVAL '14 days');

-- ---------------------------------------------------------------- verify ---
SELECT count(*) FILTER (WHERE is_compressed) AS compressed,
       count(*)                              AS total_chunks
FROM timescaledb_information.chunks WHERE hypertable_name = 'data';

SELECT pg_size_pretty(sum(before_compression_total_bytes)) AS before,
       pg_size_pretty(sum(after_compression_total_bytes))  AS after,
       round(sum(before_compression_total_bytes)::numeric
             / NULLIF(sum(after_compression_total_bytes), 0), 1) AS ratio
FROM chunk_compression_stats('public.data');

SELECT pg_size_pretty(sum(total_bytes)) AS table_total FROM chunks_detailed_size('public.data');

-- Row count must be unchanged.
SELECT count(*) AS total_rows FROM data;
