-- Create continuous aggregate for monthly data
-- This pre-computes monthly summaries and updates automatically

drop  materialized view if exists monthly_energy_summary;

// ... existing code ...
drop materialized view monthly_energy_summary;

CREATE MATERIALIZED VIEW monthly_energy_summary
    WITH (timescaledb.continuous) AS
SELECT time_bucket('1 month', tm) as month,
       first(net, tm)             as first_net,
       last(net, tm)              as last_net,
       first(p1, tm)              as first_p1,
       last(p1, tm)               as last_p1,
       first(p2, tm)              as first_p2,
       last(p2, tm)               as last_p2,
       first(n1, tm)              as first_n1,
       last(n1, tm)               as last_n1,
       first(n2, tm)              as first_n2,
       last(n2, tm)               as last_n2
FROM data
GROUP BY time_bucket('1 month', tm);

-- Create index for faster queries
// ... existing code ...;

-- Create index for faster queries
CREATE INDEX idx_monthly_summary_month ON monthly_energy_summary(month);

-- Set up refresh policy (refresh 10 days, cover last 3 months)
SELECT add_continuous_aggregate_policy('monthly_energy_summary',
    start_offset => INTERVAL '3 months',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '10 days');

-- if needed, it can be removed like this
SELECT remove_continuous_aggregate_policy('monthly_energy_summary');

-- See ALL jobs to check what columns exist
SELECT * FROM timescaledb_information.jobs;


-- Create continuous aggregate for daily data
-- This pre-computes daily summaries and updates automatically

drop materialized view  daily_energy_summary;

CREATE MATERIALIZED VIEW  daily_energy_summary2
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 day', tm) as day,
       first(net, tm)           as first_net,
       last(net, tm)            as last_net,
       first(p1, tm)            as first_p1,
       last(p1, tm)             as last_p1,
       first(p2, tm)            as first_p2,
       last(p2, tm)             as last_p2,
       first(n1, tm)            as first_n1,
       last(n1, tm)             as last_n1,
       first(n2, tm)            as first_n2,
       last(n2, tm)             as last_n2
FROM data
GROUP BY day

-- Create index for faster queries
CREATE INDEX idx_daily_summary_day ON daily_energy_summary (day);

-- Set up refresh policy (refresh every 15 minutes, cover last 740 days)
SELECT add_continuous_aggregate_policy('daily_energy_summary',
                                       start_offset => INTERVAL '740 days',
                                       end_offset => INTERVAL '1 hour',
                                       schedule_interval => INTERVAL '15 minutes');

select count(*) from daily_energy_summary;
select * from daily_energy_summary order by day desc limit 10;


SET TIME ZONE 'Europe/Amsterdam';
SELECT time_bucket('1 day', tm) as day,
       first(net, tm)           as first_net,
       last(net, tm)            as last_net,
       first(p1, tm)            as first_p1,
       last(p1, tm)             as last_p1,
       first(p2, tm)            as first_p2,
       last(p2, tm)             as last_p2,
       first(n1, tm)            as first_n1,
       last(n1, tm)             as last_n1,
       first(n2, tm)            as first_n2,
       last(n2, tm)             as last_n2,
       last(p1, tm) - first(p1, tm) as net_p1,
       last(p2, tm) - first(p2, tm) as net_p2,
       last(n1, tm) - first(n1, tm) as net_n1,
       last(n2, tm) - first(n2, tm) as net_n2,
       last(p1, tm) - first(p1, tm) + last(p2, tm) - first(p2, tm) as net_import,
       last(n1, tm) - first(n1, tm) + last(n2, tm) - first(n2, tm) as net_export,
       last(p1, tm) - first(p1, tm) + last(p2, tm) - first(p2, tm) - (last(n1, tm) - first(n1, tm) + last(n2, tm) - first(n2, tm)) as net_change
FROM data
GROUP BY time_bucket('1 day', tm);



SELECT time_bucket('1 day', tm AT TIME ZONE 'Europe/Amsterdam') as day,
       first(net, tm)           as first_net,
       last(net, tm)            as last_net,
       first(p1, tm)            as first_p1,
       last(p1, tm)             as last_p1,
       first(p2, tm)            as first_p2,
       last(p2, tm)             as last_p2,
       first(n1, tm)            as first_n1,
       last(n1, tm)             as last_n1,
       first(n2, tm)            as first_n2,
       last(n2, tm)             as last_n2,
       last(p1, tm) - first(p1, tm) as net_p1,
       last(p2, tm) - first(p2, tm) as net_p2,
       last(n1, tm) - first(n1, tm) as net_n1,
       last(n2, tm) - first(n2, tm) as net_n2,
       last(p1, tm) - first(p1, tm) + last(p2, tm) - first(p2, tm) as net_import,
       last(n1, tm) - first(n1, tm) + last(n2, tm) - first(n2, tm) as net_export,
       last(p1, tm) - first(p1, tm) + last(p2, tm) - first(p2, tm) - (last(n1, tm) - first(n1, tm) + last(n2, tm) - first(n2, tm)) as net_change
FROM data
GROUP BY time_bucket('1 day', tm AT TIME ZONE 'Europe/Amsterdam');

set timezone TO 'EUROPE/AMSTERDAM'
set timezone TO 'UTC'


-- check what the

-- Current day from live data
SELECT date_trunc('day', now())::timestamp                                                   as time,
       coalesce(last(p1, tm) - first(p1, tm), 0) + coalesce(last(p2, tm) - first(p2, tm), 0) as from_net,
       coalesce(first(n1, tm) - last(n1, tm), 0) + coalesce(first(n2, tm) - last(n2, tm), 0) as to_net,
       current_setting('TIMEZONE') as active_timezone
FROM data
WHERE tm >= date_trunc('day', now())
  AND tm < date_trunc('day', now()) + interval '1 day'


-- Check continuous aggregate policies (works across versions)
SELECT *
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_refresh_continuous_aggregate';

-- Check job statistics
SELECT *
FROM timescaledb_information.job_stats;

-- List all continuous aggregates
SELECT *
FROM timescaledb_information.continuous_aggregates;

-- Check when materialized views were last updated
SELECT materialization_hypertable_name,
       range_start,
       range_end
FROM timescaledb_information.continuous_aggregate_stats
WHERE view_name IN ('monthly_energy_summary', 'daily_energy_summary');

-- Compare latest data
SELECT MAX(day) as last_materialized_day FROM daily_energy_summary;
SELECT MAX(date_trunc('day', tm)) as last_source_day FROM data;

-- If stale, manually refresh
CALL refresh_continuous_aggregate('daily_energy_summary', NULL, NULL);
CALL refresh_continuous_aggregate('monthly_energy_summary', NULL, NULL);