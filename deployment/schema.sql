-- Authoritative schema for the youless `data` table.
--
-- This replaces the CREATE TABLE IF NOT EXISTS that used to live in
-- src/youless_dao_postgres.py. That version had drifted badly from production:
-- it still declared cs0, ps0, wtr and wts (dropped long ago), knew nothing
-- about id/uid, and created a PLAIN TABLE -- so a deploy against a fresh
-- database produced something that could never carry a continuous aggregate or
-- a compression policy.
--
-- NODE PREFIX: `uid` is a per-node marker, 'A' || id on patricia and
-- 'B' || id on pi4. Pass it in:
--   psql -v prefix=A -h <host> -U tsdb -d timescale -f schema.sql
--
-- Safe to re-run: every step is guarded.

\set ON_ERROR_STOP on

\if :{?prefix}
\else
  \echo 'ERROR: pass a node prefix, e.g.  psql -v prefix=A -f schema.sql'
  \quit 1
\endif

CREATE TABLE IF NOT EXISTS data (
    tm  TIMESTAMPTZ NOT NULL,
    net NUMERIC,
    pwr INTEGER,
    ts0 BIGINT,      -- meter S0 counter; stopped being written around 2026-01
    p1  NUMERIC,     -- import, low tariff
    p2  NUMERIC,     -- import, high tariff
    n1  NUMERIC,     -- export, low tariff
    n2  NUMERIC,     -- export, high tariff
    gas NUMERIC,
    gts BIGINT       -- gas timestamp; stopped being written around 2026-01
);

-- Per-node row identity. Order matters: the column must exist before a
-- sequence can be OWNED BY it, and before uid can be generated from it.
ALTER TABLE data ADD COLUMN IF NOT EXISTS id INTEGER;
CREATE SEQUENCE IF NOT EXISTS data_id_seq OWNED BY data.id;
ALTER TABLE data ALTER COLUMN id SET DEFAULT nextval('data_id_seq');

-- :'prefix' is interpolated by psql. It must stay outside any dollar-quoted
-- block -- psql does not substitute variables inside those.
ALTER TABLE data ADD COLUMN IF NOT EXISTS uid TEXT
    GENERATED ALWAYS AS (:'prefix' || id) STORED;

-- Hypertable. 30 days per chunk: at ~7,200 rows/day that is ~216k rows and
-- ~21 MB uncompressed per chunk, and it keeps the chunk count low enough that
-- query planning stays cheap (planning dominates these queries, not execution).
SELECT create_hypertable('data', 'tm',
                         chunk_time_interval => INTERVAL '30 days',
                         migrate_data        => true,
                         if_not_exists       => true);

CREATE INDEX IF NOT EXISTS data_tm_idx ON data (tm DESC);

-- Compression. Measured 11.5x on real data, and historical queries got 15-30%
-- FASTER because the I/O saved outweighs the decompression cost on a Pi.
-- segmentby is empty because this is a single meter.
ALTER TABLE data SET (timescaledb.compress,
                      timescaledb.compress_orderby   = 'tm DESC',
                      timescaledb.compress_segmentby = '');

SELECT add_compression_policy('data', INTERVAL '14 days', if_not_exists => true);

-- ---------------------------------------------------------------- verify ---
SELECT hypertable_name, num_chunks, compression_enabled
FROM timescaledb_information.hypertables WHERE hypertable_name = 'data';

SELECT column_name, data_type, is_generated, column_default
FROM information_schema.columns WHERE table_name = 'data' ORDER BY ordinal_position;
