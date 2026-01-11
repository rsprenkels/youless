with bucket_minmax as (with buckets as (SELECT generate_series(
                                                       date_trunc('year', now()),
                                                       date_trunc('year', now()) + interval '11 month',
                                                       interval '1 month') as month)
                       select b.month,
                              min(d.tm) as min_ts,
                              max(d.tm) as max_ts
                       from buckets b
                                left join data d on d.tm >= b.month and d.tm < b.month + interval '1 month'
                       group by 1)
select
    bmm.month::timestamp as time,
    coalesce(dmax.p1 - dmin.p1, 0) as p1,
    coalesce(dmax.p2 - dmin.p2, 0) as p2,
    coalesce(dmin.n1 - dmax.n1, 0) as n1,
    coalesce(dmin.n2 - dmax.n2, 0) as n2
from
    bucket_minmax bmm
        left join data dmin on bmm.min_ts = dmin.tm
        left join data dmax on bmm.max_ts = dmax.tm
order by
    month asc




-- Hybrid: pre-computed historical months + real-time current month
-- Fast for history, always current for this month

-- Historical months from continuous aggregate
SELECT
    month::timestamp as time,
    coalesce(last_p1 - first_p1, 0) + coalesce(last_p2 - first_p2, 0) as from_net,
    coalesce(first_n1 - last_n1, 0)  + coalesce(first_n2 - last_n2, 0) as to_net
FROM monthly_energy_summary
WHERE month >= date_trunc('year', now() - interval '1 year')
  AND month < date_trunc('month', now())

UNION ALL

-- Current month from live data
SELECT
    date_trunc('month', now())::timestamp as time,
    coalesce(last(p1, tm) - first(p1, tm), 0) + coalesce(last(p2, tm) - first(p2, tm), 0) as from_net,
    coalesce(first(n1, tm) - last(n1, tm), 0) + coalesce(first(n2, tm) - last(n2, tm), 0) as to_net
FROM data
WHERE tm >= date_trunc('month', now())
  AND tm < date_trunc('month', now()) + interval '1 month'

ORDER BY time ASC;


