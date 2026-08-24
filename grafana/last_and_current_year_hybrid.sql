-- Hybrid: pre-computed historical months + real-time current month
-- Fast for history, always current for this month

-- Historical months from continuous aggregate
SELECT
    month::timestamp as time,
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
    coalesce(last(p1, tm) - first(p1, tm), 0) as p1,
    coalesce(last(p2, tm) - first(p2, tm), 0) as p2,
    coalesce(last(n1, tm) - first(n1, tm), 0) as n1,
    coalesce(last(n2, tm) - first(n2, tm), 0) as n2
FROM data
WHERE tm > now() - interval '32 day'   -- prune guard: bare now() lets TimescaleDB exclude chunks at PLAN time
  AND tm >= date_trunc('month', now())
  AND tm < date_trunc('month', now()) + interval '1 month'

ORDER BY time ASC;
