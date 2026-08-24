-- Optimized query using continuous aggregate
-- Should be <100ms instead of ~5 seconds

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
  AND month <= date_trunc('month', now())
ORDER BY month ASC;
