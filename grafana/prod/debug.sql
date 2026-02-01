-- 1. Check if the policy exists and get its job_id
SELECT *
FROM timescaledb_information.jobs
WHERE hypertable_name = 'monthly_energy_summary'
   OR application_name LIKE '%monthly_energy_summary%';

-- 2. Check job execution history (use job_id from above)
SELECT *
FROM timescaledb_information.job_stats
WHERE job_id IN (
    SELECT job_id
    FROM timescaledb_information.jobs
    WHERE hypertable_name = 'monthly_energy_summary'
);

-- 3. Check continuous aggregate stats
SELECT view_name,
       completed_threshold,
       invalidation_threshold,
       materialization_hypertable_name
FROM timescaledb_information.continuous_aggregates
WHERE view_name = 'monthly_energy_summary';

-- 4. Compare latest materialized data vs source data
SELECT MAX(month) as last_materialized_month FROM monthly_energy_summary;
SELECT MAX(time_bucket('1 month', tm)) as last_source_month FROM data;

-- 5. Check for failed jobs
SELECT *
FROM timescaledb_information.job_errors
ORDER BY finish_time DESC
    LIMIT 10;




--
-- See ALL jobs to check what columns exist
SELECT * FROM timescaledb_information.jobs;

-- Try to add the policy again
SELECT add_continuous_aggregate_policy('monthly_energy_summary',
                                       start_offset => INTERVAL '3 months',
                                       end_offset => INTERVAL '1 day',
                                       schedule_interval => INTERVAL '10 days');

-- If that fails, check if the continuous aggregate exists
SELECT * FROM timescaledb_information.continuous_aggregates;