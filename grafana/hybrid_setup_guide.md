# Hybrid Query Setup Guide - Step by Step

## Prerequisites
- TimescaleDB is running
- You have access to the database (user: tsdb, database: timescale)
- Table name: `data` with columns: `tm`, `net`, `p1`, `p2`, `n1`, `n2`

---

## Step 1: Create the Continuous Aggregate

Connect to your database and run:

```bash
psql -h <host> -U tsdb -d timescale
```

Then execute:

```sql
CREATE MATERIALIZED VIEW monthly_energy_summary
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 month', tm) as month,
    first(net, tm) as first_net,
    last(net, tm) as last_net,
    first(p1, tm) as first_p1,
    last(p1, tm) as last_p1,
    first(p2, tm) as first_p2,
    last(p2, tm) as last_p2,
    first(n1, tm) as first_n1,
    last(n1, tm) as last_n1,
    first(n2, tm) as first_n2,
    last(n2, tm) as last_n2
FROM data
GROUP BY time_bucket('1 month', tm);
```

**Expected output**: `SELECT 0` (success message)

---

## Step 2: Create Index

```sql
CREATE INDEX idx_monthly_summary_month ON monthly_energy_summary(month);
```

**Expected output**: `CREATE INDEX`

---

## Step 3: Set Up Auto-Refresh Policy

This refreshes the aggregate every hour, covering data up to 1 hour ago:

```sql
SELECT add_continuous_aggregate_policy('monthly_energy_summary',
    start_offset => INTERVAL '3 months',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 hour');
```

**Expected output**: Job ID number (e.g., `1001`)

---

## Step 4: Initial Data Population

Force an immediate refresh to populate historical data:

```sql
CALL refresh_continuous_aggregate('monthly_energy_summary', NULL, NULL);
```

**This may take a few seconds** - it's processing all your historical data.

**Expected output**: `CALL`

---

## Step 5: Verify the Continuous Aggregate

Check that data was created:

```sql
SELECT month, first_net, last_net, last_net - first_net as total
FROM monthly_energy_summary
ORDER BY month DESC
LIMIT 5;
```

**Expected output**: Should show your most recent 5 months with data.

---

## Step 6: Test the Hybrid Query

Run the optimized query:

```sql
EXPLAIN ANALYZE
-- Historical months from continuous aggregate
SELECT
    month::timestamp as time,
    first_net as min_net,
    last_net as max_net,
    last_net - first_net as total,
    coalesce(last_p1 - first_p1, 0) as p1,
    coalesce(last_p2 - first_p2, 0) as p2,
    coalesce(last_n1 - first_n1, 0) as n1,
    coalesce(last_n2 - first_n2, 0) as n2
FROM monthly_energy_summary
WHERE month >= date_trunc('year', now() - interval '1 year')
  AND month < date_trunc('month', now())

UNION ALL

-- Current month from live data
SELECT
    date_trunc('month', now())::timestamp as time,
    first(net, tm) as min_net,
    last(net, tm) as max_net,
    last(net, tm) - first(net, tm) as total,
    coalesce(last(p1, tm) - first(p1, tm), 0) as p1,
    coalesce(last(p2, tm) - first(p2, tm), 0) as p2,
    coalesce(last(n1, tm) - first(n1, tm), 0) as n1,
    coalesce(last(n2, tm) - first(n2, tm), 0) as n2
FROM data
WHERE tm >= date_trunc('month', now())
  AND tm < date_trunc('month', now()) + interval '1 month'

ORDER BY time ASC;
```

**Look for**: `Execution Time` at the bottom - should be **< 200ms** (vs your current ~4900ms)

---

## Step 7: Update Grafana Query

1. Open your Grafana dashboard
2. Edit the panel that uses `last_and_current_year.sql`
3. Replace the query with:

```sql
-- Historical months from continuous aggregate
SELECT
    month::timestamp as time,
    first_net as min_net,
    last_net as max_net,
    last_net - first_net as total,
    coalesce(last_p1 - first_p1, 0) as p1,
    coalesce(last_p2 - first_p2, 0) as p2,
    coalesce(last_n1 - first_n1, 0) as n1,
    coalesce(last_n2 - first_n2, 0) as n2
FROM monthly_energy_summary
WHERE month >= date_trunc('year', now() - interval '1 year')
  AND month < date_trunc('month', now())

UNION ALL

-- Current month from live data
SELECT
    date_trunc('month', now())::timestamp as time,
    first(net, tm) as min_net,
    last(net, tm) as max_net,
    last(net, tm) - first(net, tm) as total,
    coalesce(last(p1, tm) - first(p1, tm), 0) as p1,
    coalesce(last(p2, tm) - first(p2, tm), 0) as p2,
    coalesce(last(n1, tm) - first(n1, tm), 0) as n1,
    coalesce(last(n2, tm) - first(n2, tm), 0) as n2
FROM data
WHERE tm >= date_trunc('month', now())
  AND tm < date_trunc('month', now()) + interval '1 month'

ORDER BY time ASC;
```

4. Save and test the panel

---

## Step 8: Monitor Refresh Job

Check that the auto-refresh job is running:

```sql
SELECT * FROM timescaledb_information.jobs
WHERE proc_name = 'policy_refresh_continuous_aggregate';
```

Check recent job runs:

```sql
SELECT * FROM timescaledb_information.job_stats
WHERE job_id IN (
    SELECT job_id FROM timescaledb_information.jobs
    WHERE proc_name = 'policy_refresh_continuous_aggregate'
)
ORDER BY last_run_started_at DESC;
```

---

## Troubleshooting

### If continuous aggregate is empty:
```sql
CALL refresh_continuous_aggregate('monthly_energy_summary', NULL, NULL);
```

### If you need to drop and recreate:
```sql
DROP MATERIALIZED VIEW monthly_energy_summary CASCADE;
-- Then go back to Step 1
```

### Check what data exists in base table:
```sql
SELECT min(tm), max(tm), count(*) FROM data;
```

### Verify TimescaleDB extension:
```sql
SELECT * FROM pg_extension WHERE extname = 'timescaledb';
```

---

## Expected Performance

- **Old query**: ~4900ms (4.9 seconds)
- **New hybrid query**: ~100-200ms (0.1-0.2 seconds)
- **Improvement**: ~25x faster
- **Current month data**: Real-time (no delay)
- **Historical months**: Updated hourly (but static anyway)

---

## Maintenance

The continuous aggregate will:
- Auto-refresh every hour
- Only process new data in the current/recent months
- Require no manual intervention

Optional: If you want to change refresh frequency:
```sql
-- Remove old policy
SELECT remove_continuous_aggregate_policy('monthly_energy_summary');

-- Add new policy (e.g., every 30 minutes)
SELECT add_continuous_aggregate_policy('monthly_energy_summary',
    start_offset => INTERVAL '3 months',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '30 minutes');
```
