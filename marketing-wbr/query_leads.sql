-- Marketing WBR — leads + calificados (CO)
-- Output: one row per (dia, channel) with reg + cal counts.
-- Window: last 180 days, excludes today.
-- Channel logic: UTM mkt_channel_medium, fallback "{fuente} Direct" when no campaign.

WITH utm_dedup AS (
  SELECT *
  FROM `sellers-main-prod.bi_co.registro_unico_utm_mkt_colombia`
  QUALIFY ROW_NUMBER() OVER(PARTITION BY campana_mercadeo_original ORDER BY campana_mercadeo_original) = 1
),

leads AS (
  SELECT
    g.negocio_id,
    DATE(g.fecha_creacion) AS dia,
    CASE
      -- lead_forms is collapsed (Paid + Direct) into a single channel
      WHEN g.fuente IN ('lead_forms', 'Lead Forms') THEN 'lead_forms'
      WHEN g.campana_mercadeo IS NULL OR g.campana_mercadeo = ''
        THEN CONCAT(g.fuente, ' Direct')
      WHEN m.mkt_channel_medium IS NULL OR m.mkt_channel_medium = ''
        THEN g.campana_mercadeo
      ELSE m.mkt_channel_medium
    END AS channel
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` g
  LEFT JOIN utm_dedup m ON g.campana_mercadeo = m.campana_mercadeo_original
  WHERE g.fuente_id IN (3, 7, 20, 35, 39, 47)
    AND DATE(g.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
    AND DATE(g.fecha_creacion) < CURRENT_DATE()
),

cal AS (
  SELECT negocio_id, MIN(fecha_actualizacion) AS cal_ts
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
  WHERE estado_id IN (20, 63)
  GROUP BY 1
)

SELECT
  CAST(l.dia AS STRING) AS dia,
  l.channel,
  COUNT(*) AS reg,
  COUNTIF(c.cal_ts IS NOT NULL) AS cal
FROM leads l
LEFT JOIN cal c ON c.negocio_id = l.negocio_id
GROUP BY 1, 2
ORDER BY 1, 2
