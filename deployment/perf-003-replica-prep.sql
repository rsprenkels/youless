-- perf-003: prepare the pi4 replica to receive a full sync.
--
-- Found 2026-08-24: `data` on pi4 is a PLAIN TABLE with NO INDEXES AT ALL,
-- even though TimescaleDB 2.24 is installed. That is the real reason
-- data_sync.py has never completed: its per-row
--     WHERE NOT EXISTS (SELECT 1 FROM data WHERE tm = %s)
-- does a full 684k-row sequential scan for every one of 3.3M source rows.
--
-- Converting to a hypertable now, while the table is still small (684k rows,
-- 87 MB), is much cheaper than converting after the 2.65M missing rows land.
-- create_hypertable also creates the tm index that the anti-join sync needs.
--
-- Takes an ACCESS EXCLUSIVE lock on `data` while it rewrites rows into chunks.
-- pi4 is a read-only replica (nothing has written to it since 2026-05-18), so
-- this should be uneventful, but it is not instant.
--
-- Not reversible in place: undoing means creating a plain table and copying back.
--
-- Run against pi4:
--   psql -h pi4 -U tsdb -d timescale -f perf-003-replica-prep.sql

\timing on

SELECT create_hypertable(
    'data', 'tm',
    chunk_time_interval => INTERVAL '30 days',
    migrate_data        => true
);

-- ---------------------------------------------------------------- verify ---
SELECT hypertable_name, num_chunks FROM timescaledb_information.hypertables;
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'data';
SELECT count(*) AS rows, min(tm), max(tm) FROM data;
