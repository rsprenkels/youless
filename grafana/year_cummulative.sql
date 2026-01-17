-- WITH daily AS (
--     SELECT
--         date_trunc('day', tm)::date                        AS day,
--         EXTRACT(year FROM tm)::int                         AS year,
--         EXTRACT(doy  FROM tm)::int                         AS doy,
--         SUM(kwh_import - kwh_export)                       AS net_kwh
--     FROM energy_data
--     WHERE tm >= date_trunc('year', now()) - interval '5 years'
--     GROUP BY 1, 2, 3
-- ),
--      ytd AS (
--          SELECT
--              year,
--              doy,
--              SUM(net_kwh) OVER (
--                  PARTITION BY year
--                  ORDER BY doy
--                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--                  ) AS cumulative_kwh
--          FROM daily
--      )
-- SELECT
--     -- fake timestamp so Grafana can plot it on X-axis
--     make_date(2000, 1, 1) + (doy - 1) * interval '1 day' AS time,
--     cumulative_kwh                                     AS value,
--     year::text                                         AS metric
-- FROM ytd
-- ORDER BY year, time;

SELECT
    date_trunc('day', tm)::date                        AS day,
    EXTRACT(year FROM tm)::int                         AS year,
    EXTRACT(doy  FROM tm)::int                         AS doy,
    SUM(kwh_import - kwh_export)                       AS net_kwh
FROM daily_energy_summary
WHERE tm >= date_trunc('year', now()) - interval '5 years'
GROUP BY 1, 2, 3


select * from daily_energy_summary
order by day desc