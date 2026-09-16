-- Exported verbatim from the live "Energie" dashboard, v60 (2026-09-16).
-- Do not hand-edit: Grafana keeps its own copy in grafana.db, so a hand edit
-- here just drifts again the next time someone changes a panel there.
-- Re-export via the API instead -- see TODO.md #4. Full dashboard JSON:
-- deployment/grafana-energie-v60-backup.json

-- Panel id=2 "power"
SELECT $__timeGroup(tm,$__interval) AS "time", AVG(pwr) AS "value" FROM data WHERE $__timeFilter(tm) GROUP BY 1

-- Panel id=7 "last 14 days" (13+1 day window)
-- Historical days from continuous aggregate
SELECT (day AT TIME ZONE 'Europe/Amsterdam')                                                    as time,
       coalesce(last_p1 - first_p1, 0) + coalesce(last_p2 - first_p2, 0) as from_net,
       coalesce(first_n1 - last_n1, 0) + coalesce(first_n2 - last_n2, 0) as to_net
FROM daily_energy_summary
WHERE day >= date_trunc('day', (now() - interval '13 day') AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND day < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'

UNION ALL

-- Current day from live data
SELECT date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam')                                                   as time,
       coalesce(last(p1, tm) - first(p1, tm), 0) + coalesce(last(p2, tm) - first(p2, tm), 0) as from_net,
       coalesce(first(n1, tm) - last(n1, tm), 0) + coalesce(first(n2, tm) - last(n2, tm), 0) as to_net
FROM data
WHERE tm > now() - interval '2 day'   -- prune guard: bare now() lets TimescaleDB exclude chunks at PLAN time
  AND tm >= date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND tm < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam' + interval '1 day'

ORDER BY time ASC;

-- Panel id=8 "last 7 days"
-- Historical days from continuous aggregate
SELECT (day AT TIME ZONE 'Europe/Amsterdam')                                                    as time,
       coalesce(last_p1 - first_p1, 0) + coalesce(last_p2 - first_p2, 0) as from_net,
       coalesce(first_n1 - last_n1, 0) + coalesce(first_n2 - last_n2, 0) as to_net
FROM daily_energy_summary
WHERE day >= date_trunc('day', (now() - interval '6 day') AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND day < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'

UNION ALL

-- Current day from live data
SELECT date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam')                                                   as time,
       coalesce(last(p1, tm) - first(p1, tm), 0) + coalesce(last(p2, tm) - first(p2, tm), 0) as from_net,
       coalesce(first(n1, tm) - last(n1, tm), 0) + coalesce(first(n2, tm) - last(n2, tm), 0) as to_net
FROM data
WHERE tm > now() - interval '2 day'   -- prune guard: bare now() lets TimescaleDB exclude chunks at PLAN time
  AND tm >= date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND tm < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam' + interval '1 day'

ORDER BY time ASC;

-- Panel id=9 "last 14 days" (21+1 day window, adds net_change -- note this
-- is a second, differently-scoped panel also titled "last 14 days" on the
-- live dashboard; that duplicate title is live-dashboard state, not a repo bug)
-- Historical days from continuous aggregate
SELECT (day AT TIME ZONE 'Europe/Amsterdam')                                                    as time,
       coalesce(last_p1 - first_p1, 0) + coalesce(last_p2 - first_p2, 0) as from_net,
       coalesce(first_n1 - last_n1, 0) + coalesce(first_n2 - last_n2, 0) as to_net,
       coalesce(last_p1 - first_p1, 0) + coalesce(last_p2 - first_p2, 0) + coalesce(first_n1 - last_n1, 0) + coalesce(first_n2 - last_n2, 0) as net_change
FROM daily_energy_summary
WHERE day >= date_trunc('day', (now() - interval '21 day') AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND day < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'

UNION ALL

-- Current day from live data
SELECT date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam')                                                   as time,
       coalesce(last(p1, tm) - first(p1, tm), 0) + coalesce(last(p2, tm) - first(p2, tm), 0) as from_net,
       coalesce(first(n1, tm) - last(n1, tm), 0) + coalesce(first(n2, tm) - last(n2, tm), 0) as to_net,
       coalesce(last(p1, tm) - first(p1, tm), 0) + coalesce(last(p2, tm) - first(p2, tm), 0) + coalesce(first(n1, tm) - last(n1, tm), 0) + coalesce(first(n2, tm) - last(n2, tm), 0) as net_change
FROM data
WHERE tm > now() - interval '2 day'   -- prune guard: bare now() lets TimescaleDB exclude chunks at PLAN time
  AND tm >= date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
  AND tm < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam' + interval '1 day'

ORDER BY time ASC;

-- Panel id=10 "running_total"
WITH daily_net AS (
    -- daily deltas for current year
    SELECT
        (day AT TIME ZONE 'Europe/Amsterdam') as time,
        coalesce(last_p1 - first_p1, 0)
            + coalesce(last_p2 - first_p2, 0)
            + coalesce(first_n1 - last_n1, 0)
            + coalesce(first_n2 - last_n2, 0) as net_change
    FROM daily_energy_summary
    WHERE day >= date_trunc('year', (now() - interval '0 year') AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
      AND day < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'

    UNION ALL

    -- current day from live data
    SELECT
        date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') as time,
        coalesce(last(p1, tm) - first(p1, tm), 0)
            + coalesce(last(p2, tm) - first(p2, tm), 0)
            + coalesce(first(n1, tm) - last(n1, tm), 0)
            + coalesce(first(n2, tm) - last(n2, tm), 0) as net_change
    FROM data
    WHERE tm > now() - interval '2 day'   -- prune guard: bare now() lets TimescaleDB exclude chunks at PLAN time
  AND tm >= date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam'
      AND tm < date_trunc('day', now() AT TIME ZONE 'Europe/Amsterdam') AT TIME ZONE 'Europe/Amsterdam' + interval '1 day'
)

SELECT
    time,
    net_change,
    sum(net_change) OVER (
        ORDER BY time
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) as running_total
FROM daily_net
ORDER BY time ASC;