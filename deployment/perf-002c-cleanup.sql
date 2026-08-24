-- perf-002 part C: retire the UTC-bucketed aggregates and promote the v2 ones.
-- DESTRUCTIVE. Run only after perf-002b-policies.sql and verification.
--
-- The dropped views are derived data, fully rebuildable from `data` by
-- re-running perf-002-timezone-aware-caggs.sql. Dropping a CAgg also drops
-- its refresh policy (jobs 1002 and 1004 disappear with them).
--
-- After the rename, jobs 1006/1007 follow the views to their new names, and
-- the five Grafana panels keep working unchanged: they already run
-- SET TIME ZONE 'Europe/Amsterdam', so date_trunc('day', now()) there is
-- already local midnight and now matches the aggregate's bucket boundaries.

\timing on

-- Orphan from the botched create script: no refresh policy, frozen at
-- 2026-01-10, referenced by no panel and no other object.
DROP MATERIALIZED VIEW daily_energy_summary2;

DROP MATERIALIZED VIEW daily_energy_summary;
DROP MATERIALIZED VIEW monthly_energy_summary;

ALTER MATERIALIZED VIEW daily_energy_summary_v2   RENAME TO daily_energy_summary;
ALTER MATERIALIZED VIEW monthly_energy_summary_v2 RENAME TO monthly_energy_summary;

-- ---------------------------------------------------------------- verify ---
SELECT view_name, materialization_hypertable_name
FROM timescaledb_information.continuous_aggregates ORDER BY view_name;

SELECT job_id, hypertable_name AS view, schedule_interval, config->>'end_offset' AS end_offset
FROM timescaledb_information.jobs
WHERE proc_name='policy_refresh_continuous_aggregate' ORDER BY job_id;
