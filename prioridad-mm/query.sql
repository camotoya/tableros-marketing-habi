-- Prioridad de gestión Market Maker (HubSpot) — distribución A/B/C por semana × país
-- Últimas 18 semanas ISO completas (excluye la semana en curso).
WITH base AS (
  SELECT
    DATE_TRUNC(DATE(createdate), ISOWEEK) AS semana,
    country,
    prioridad_gestion_market_maker AS prioridad
  FROM `sellers-main-prod.hubspot.deals`
  WHERE prioridad_gestion_market_maker IN ('A','B','C')
    AND country IN ('Colombia','México')
    AND DATE_TRUNC(DATE(createdate), ISOWEEK) >=
        DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 18 WEEK), ISOWEEK)
    AND DATE_TRUNC(DATE(createdate), ISOWEEK) <
        DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
)
SELECT
  FORMAT_DATE('%Y-%m-%d', semana) AS semana,
  country,
  COUNT(*) AS n,
  COUNTIF(prioridad='A') AS a,
  COUNTIF(prioridad='B') AS b,
  COUNTIF(prioridad='C') AS c
FROM base
GROUP BY 1, 2
ORDER BY 1, 2
