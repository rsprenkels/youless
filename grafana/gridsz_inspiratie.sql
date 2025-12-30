WITH hours AS (SELECT generate_series(
                              date_trunc('hour', $__timeFrom()::timestamp),
                              date_trunc('hour', $__timeTo()::timestamp),
                              interval '1 hour'
                      ) AS bucket),
     series AS (
         -- all distinct status/type combinations in the selected time window
         SELECT DISTINCT status_name, type
         FROM orders_met_aansluitingen
         WHERE $__timeFilter(created)),
     grid AS (
         -- full matrix: every hour × every status/type
         SELECT h.bucket,
                s.status_name,
                s.type
         FROM hours h
                  CROSS JOIN series s),
     agg AS (
         -- your actual counts per hour/status/type
         SELECT date_trunc('hour', created) AS bucket,
                status_name,
                type,
                COUNT(id)                   AS number
         FROM orders_met_aansluitingen
         WHERE $__timeFilter(created)
         GROUP BY 1, 2, 3)
SELECT g.bucket              AS "time",
       g.status_name         AS "status",
       g.type                AS "category",
       COALESCE(a.number, 0) AS number
FROM grid g
         LEFT JOIN agg a
                   ON a.bucket = g.bucket
                       AND a.status_name = g.status_name
                       AND a.type = g.type
ORDER BY 1, 2, 3;
