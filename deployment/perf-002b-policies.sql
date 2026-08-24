-- perf-002 part B: refresh policies for the timezone-aware aggregates.
-- Non-destructive. Policies follow the view across a later RENAME.
--
-- end_offset of 1 hour puts the window end inside the current bucket, so a
-- policy refresh (which rounds inward to whole buckets) materializes only
-- COMPLETE local days/months -- while picking the previous month up within an
-- hour of rollover, instead of the old 10-day schedule_interval that could
-- leave the previous month's bar missing for up to 10 days.

\timing on

SELECT add_continuous_aggregate_policy('daily_energy_summary_v2',
    start_offset      => INTERVAL '740 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '15 minutes');

SELECT add_continuous_aggregate_policy('monthly_energy_summary_v2',
    start_offset      => INTERVAL '3 months',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');
