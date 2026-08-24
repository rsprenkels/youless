-- perf-001: enable columnar compression + widen chunk interval
--
-- Measured on patricia, 2026-08-24, against a single test chunk that was
-- compressed and then decompressed again (_hyper_2_78_chunk, 2026-03-12..19,
-- 61,304 rows):
--
--   size    10,008 kB -> 936 kB  = 10.7x     (heap 7,576 kB -> 48 kB)
--   first/last over the week   10.5 ms -> 9.0 ms   (-14%)
--   avg(pwr) full scan         19.5 ms -> 13.5 ms  (-31%)
--   daily buckets over week    38.4 ms -> 27.5 ms  (-28%)
--   count(*)                   19.2 ms -> 12.8 ms  (-33%)
--
-- Compression made every query FASTER, not slower: on a Pi the I/O saved by
-- reading 48 kB instead of 7,576 kB outweighs the decompression CPU.
--
-- Expected whole-table effect: 571 MB -> ~53 MB.
-- Old (ts0/gts populated) and new chunks average within 1% of each other,
-- so the ratio should hold across the full history.

\timing on

-- 1. Compression settings.
--    segmentby is empty because this is a single meter. If `uid` ever holds
--    more than one device, switch to compress_segmentby = 'uid'.
ALTER TABLE data SET (timescaledb.compress,
                      timescaledb.compress_orderby   = 'tm DESC',
                      timescaledb.compress_segmentby = '');

-- 2. Compress anything older than 14 days (= 2 chunk intervals), so the chunk
--    currently being written by the daemon is never touched.
SELECT add_compression_policy('data', INTERVAL '14 days', if_not_exists => true);

-- 3. Compress the existing backlog now instead of waiting for the policy.
--    ~210 ms per chunk, so roughly 12 s for the current 59 chunks.
SELECT compress_chunk(show_chunks, if_not_compressed => true)
FROM show_chunks('data', older_than => INTERVAL '14 days');

-- 4. Widen chunk interval 7 days -> 1 month.
--    Affects NEW chunks only; the existing 59 chunks keep their 7-day ranges,
--    so planning cost falls gradually rather than immediately.
SELECT set_chunk_time_interval('data', INTERVAL '1 month');


-- ---------------------------------------------------------------- verify ---
SELECT count(*) FILTER (WHERE is_compressed) AS compressed,
       count(*)                              AS total_chunks
FROM timescaledb_information.chunks WHERE hypertable_name = 'data';

SELECT pg_size_pretty(sum(before_compression_total_bytes)) AS before,
       pg_size_pretty(sum(after_compression_total_bytes))  AS after,
       round(sum(before_compression_total_bytes)::numeric
             / NULLIF(sum(after_compression_total_bytes), 0), 1) AS ratio
FROM chunk_compression_stats('public.data');

-- Row count must be unchanged by all of the above.
SELECT count(*) AS total_rows FROM data;


-- -------------------------------------------------------------- rollback ---
-- SELECT remove_compression_policy('data');
-- SELECT decompress_chunk(show_chunks, if_compressed => true) FROM show_chunks('data');
-- ALTER TABLE data SET (timescaledb.compress = false);
-- SELECT set_chunk_time_interval('data', INTERVAL '7 days');
