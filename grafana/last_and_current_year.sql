with bucket_minmax as (with buckets as (SELECT generate_series(
                                                      date_trunc('year', now() - interval '1 year'),
                                                      date_trunc('month', now()),
                                                      interval '1 month') as month)
                      select b.month,
                             min(d.tm) as min_ts,
                             max(d.tm) as max_ts
                      from buckets b
                               left join data d on d.tm >= b.month and d.tm < b.month + interval '1 month'
                      group by 1)
select
    bmm.month::timestamp as time,
    dmin.net as min_net,
    dmax.net as max_net,
    dmax.net - dmin.net as total,
    coalesce(dmax.p1 - dmin.p1, 0) as p1,
    coalesce(dmax.p2 - dmin.p2, 0) as p2,
    coalesce(dmax.n1 - dmin.n1, 0) as n1,
    coalesce(dmax.n2 - dmin.n2, 0) as n2
from
    bucket_minmax bmm
    left join data dmin on bmm.min_ts = dmin.tm
    left join data dmax on bmm.max_ts = dmax.tm
order by
    month asc


CREATE INDEX idx_data_tm ON data(tm);