-- Exported verbatim from the live "Energie" dashboard, v60 (2026-09-16).
-- Do not hand-edit: Grafana keeps its own copy in grafana.db, so a hand edit
-- here just drifts again the next time someone changes a panel there.
-- Re-export via the API instead -- see TODO.md #4. Full dashboard JSON:
-- deployment/grafana-energie-v60-backup.json

-- Panel id=5 "last and current year per month"
-- Hybrid: pre-computed historical months + real-time current month
-- Fast for history, always current for this month
-- Historical months from continuous aggregate
SELECT
    (month AT TIME ZONE 'Europe/Amsterdam') as time,
    coalesce(last_p1 - first_p1, 0) + coalesce(last_p2 - first_p2, 0) as from_net,
    coalesce(first_n1 - last_n1, 0)  + coalesce(first_n2 - last_n2, 0) as to_net
FROM monthly_energy_summary
WHERE month >= date_trunc('year', (now() - interval '1 year') AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND month < date_trunc('month', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'

UNION ALL

-- Current month from live data
SELECT
    date_trunc('month', now() AT TIME ZONE 'Europe/Amsterdam') as time,
    coalesce(last(p1, tm) - first(p1, tm), 0) + coalesce(last(p2, tm) - first(p2, tm), 0) as from_net,
    coalesce(first(n1, tm) - last(n1, tm), 0) + coalesce(first(n2, tm) - last(n2, tm), 0) as to_net
FROM data
WHERE tm > now() - interval '32 day'   -- prune guard: bare now() lets TimescaleDB exclude chunks at PLAN time
  AND tm >= date_trunc('month', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND tm < date_trunc('month', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam' + interval '1 month'

ORDER BY time ASC;