-- Marketing WBR — spend by (dia, channel) (CO)
-- Output: one row per (dia, channel) with summed spend.
-- Channel via JOIN i.campana = m.mkt_campaign_name (UTM dict).
-- Spend without channel match is dropped (reported separately).

WITH utm_dedup AS (
  SELECT *
  FROM `sellers-main-prod.bi_co.registro_unico_utm_mkt_colombia`
  QUALIFY ROW_NUMBER() OVER(PARTITION BY mkt_campaign_name ORDER BY mkt_campaign_name) = 1
)

SELECT
  CAST(i.date AS STRING) AS dia,
  m.mkt_channel_medium AS channel,
  ROUND(SUM(i.spend), 0) AS spend
FROM `papyrus-data.habi_wh_bi.resumen_inversiones_mkt_co` i
LEFT JOIN utm_dedup m ON i.campana = m.mkt_campaign_name
WHERE i.date >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
  AND i.date < CURRENT_DATE()
  AND m.mkt_channel_medium IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2
