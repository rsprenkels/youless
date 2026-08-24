-- perf-002: rebuild continuous aggregates with timezone-aware buckets,
--           and fix the monthly refresh cadence.
--
-- PROBLEM 1 (correctness): the CAggs bucketed with time_bucket('1 day', tm),
-- which is UTC-aligned, while every panel runs SET TIME ZONE 'Europe/Amsterdam'.
-- A local day therefore ran 22:00->22:00 UTC in summer / 23:00->23:00 in winter,
-- but the aggregate cut at 00:00 UTC. Measured error on 2026-08-24:
--
--   day          shown     true     error
--   2026-08-14   6.710     5.257    -21.7%
--   2026-08-15   8.621    10.021    +16.2%
--   2026-08-16.. 4.212     4.244      0.8%   (typical day: 0.1-3%)
--
-- PROBLEM 2 (staleness): monthly_energy_summary refreshed on a 10-day
-- schedule_interval. A CAgg refresh rounds its window inward to whole buckets,
-- so the just-finished month is only materialized once now()-end_offset passes
-- the 1st -- then up to 10 more days before the job runs. Meanwhile the hybrid
-- panel reads the CAgg for every month < current, so the previous month reads
-- as absent for up to ~10 days after each rollover.
--
-- FIX: bucket with the 3-arg time_bucket(interval, ts, timezone), and schedule
-- the monthly refresh hourly. Panels need NO changes: they already set the
-- session timezone, so date_trunc('day', now()) there is already local midnight
-- and now lines up exactly with the aggregate's bucket boundaries.

\timing on

-- ---------------------------------------------------------------- part A ---
-- Build alongside the existing aggregates; nothing is dropped yet.

CREATE MATERIALIZED VIEW daily_energy_summary_v2
    WITH (timescaledb.continuous) AS
SELECT time_bucket('1 day', tm, 'Europe/Amsterdam') AS day,
       first(net, tm) AS first_net, last(net, tm) AS last_net,
       first(p1, tm)  AS first_p1,  last(p1, tm)  AS last_p1,
       first(p2, tm)  AS first_p2,  last(p2, tm)  AS last_p2,
       first(n1, tm)  AS first_n1,  last(n1, tm)  AS last_n1,
       first(n2, tm)  AS first_n2,  last(n2, tm)  AS last_n2
FROM data
GROUP BY 1
WITH NO DATA;

CREATE MATERIALIZED VIEW monthly_energy_summary_v2
    WITH (timescaledb.continuous) AS
SELECT time_bucket('1 month', tm, 'Europe/Amsterdam') AS month,
       first(net, tm) AS first_net, last(net, tm) AS last_net,
       first(p1, tm)  AS first_p1,  last(p1, tm)  AS last_p1,
       first(p2, tm)  AS first_p2,  last(p2, tm)  AS last_p2,
       first(n1, tm)  AS first_n1,  last(n1, tm)  AS last_n1,
       first(n2, tm)  AS first_n2,  last(n2, tm)  AS last_n2
FROM data
GROUP BY 1
WITH NO DATA;

CALL refresh_continuous_aggregate('daily_energy_summary_v2',   NULL, NULL);
CALL refresh_continuous_aggregate('monthly_energy_summary_v2', NULL, NULL);

SELECT 'daily_v2'   AS view, count(*) AS buckets, min(day)::date,   max(day)::date   FROM daily_energy_summary_v2
UNION ALL
SELECT 'monthly_v2',         count(*),            min(month)::date, max(month)::date FROM monthly_energy_summary_v2;
