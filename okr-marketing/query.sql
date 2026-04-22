-- OKR Marketing: daily investment by country (2025-2026)
-- Daily granularity allows aggregation by week/cycle in Python
-- Excludes current day (data may be incomplete)
SELECT
  'CO' AS country,
  CAST(date AS STRING) AS dt,
  ROUND(SUM(spend), 0) AS spend
FROM `papyrus-data.habi_wh_bi.resumen_inversiones_mkt_co`
WHERE date >= '2025-01-01'
  AND date < CURRENT_DATE()
GROUP BY 1, 2

UNION ALL

SELECT
  'MX',
  CAST(date AS STRING),
  ROUND(SUM(spend), 0)
FROM `papyrus-data-mx.habi_wh_bi.resumen_inversiones_mkt_mx`
WHERE date >= '2025-01-01'
  AND date < CURRENT_DATE()
GROUP BY 1, 2

ORDER BY 1, 2
