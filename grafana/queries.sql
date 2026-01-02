

SELECT
    *
FROM
    data
WHERE
    tm >= NOW() - interval '7 days'


select count(*) from data_test