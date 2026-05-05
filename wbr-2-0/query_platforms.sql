-- WBR 2.0 — Métricas semanales por plataforma × canal × fuente (CO)
-- Plataforma viene de UTM dict (mkt_platform).
-- Output: one row per (week_start, platform, channel, fuente) with reg, cal, asg, spend.
-- Solo leads con UTM (los Direct/sin tracking no aparecen — no tienen platform).

WITH
  utm_dedup AS (
    SELECT *
    FROM `sellers-main-prod.bi_co.registro_unico_utm_mkt_colombia`
    QUALIFY ROW_NUMBER() OVER(PARTITION BY campana_mercadeo_original ORDER BY campana_mercadeo_original) = 1
  ),
  utm_dedup_camp AS (
    SELECT *
    FROM `sellers-main-prod.bi_co.registro_unico_utm_mkt_colombia`
    QUALIFY ROW_NUMBER() OVER(PARTITION BY mkt_campaign_name ORDER BY mkt_campaign_name) = 1
  ),
  leads AS (
    SELECT
      g.nid, g.negocio_id, g.fuente, g.fuente_id,
      DATE(g.fecha_creacion) AS reg_date,
      CASE g.fuente_id
        WHEN 3  THEN 'WEB'
        WHEN 7  THEN 'Estudio Inmueble'
        WHEN 20 THEN 'CRM'
        WHEN 35 THEN 'Comercial'
        WHEN 39 THEN 'Broker'
        WHEN 47 THEN 'lead_forms'
      END AS fuente_canon,
      CASE
        WHEN g.fuente IN ('lead_forms', 'Lead Forms') THEN 'lead_forms'
        WHEN m.mkt_channel_medium IS NULL OR m.mkt_channel_medium = ''
          THEN g.campana_mercadeo
        ELSE m.mkt_channel_medium
      END AS channel,
      m.mkt_platform AS platform
    FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` g
    JOIN utm_dedup m ON g.campana_mercadeo = m.campana_mercadeo_original
    WHERE g.fuente_id IN (3, 7, 20, 35, 39, 47)
      AND m.mkt_platform IS NOT NULL
      AND m.mkt_platform != ''
      AND DATE(g.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
  ),
  cal AS (
    SELECT negocio_id, MIN(fecha_actualizacion) AS cal_ts
    FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
    WHERE estado_id IN (20, 63)
    GROUP BY 1
    HAVING MIN(fecha_actualizacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 140 DAY)
      AND MIN(fecha_actualizacion) < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
  ),
  reg_agg AS (
    SELECT DATE_TRUNC(reg_date, ISOWEEK) AS week,
      platform, channel, fuente_canon AS fuente, COUNT(*) AS n
    FROM leads
    WHERE reg_date >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 140 DAY), ISOWEEK)
      AND reg_date < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
    GROUP BY 1, 2, 3, 4
  ),
  cal_agg AS (
    SELECT DATE_TRUNC(DATE(c.cal_ts), ISOWEEK) AS week,
      l.platform, l.channel, l.fuente_canon AS fuente, COUNT(*) AS n
    FROM cal c
    JOIN leads l ON l.negocio_id = c.negocio_id
    GROUP BY 1, 2, 3, 4
  ),
  asg_agg AS (
    SELECT DATE_TRUNC(a.dia, ISOWEEK) AS week,
      l.platform, l.channel, l.fuente_canon AS fuente, COUNT(*) AS n
    FROM `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart` a
    JOIN leads l ON l.nid = a.nid
    WHERE a.pais = 'colombia'
      AND a.fuente_id_tig IN (3, 7, 20, 35, 39, 47)
      AND a.dia >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 140 DAY), ISOWEEK)
      AND a.dia < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
    GROUP BY 1, 2, 3, 4
  ),
  spend_agg AS (
    SELECT
      DATE_TRUNC(i.date, ISOWEEK) AS week,
      m.mkt_platform AS platform,
      CASE
        WHEN m.mkt_channel_medium IN ('lead_forms Paid', 'lead_forms Direct') THEN 'lead_forms'
        ELSE m.mkt_channel_medium
      END AS channel,
      CASE
        WHEN m.mkt_channel_medium LIKE 'WEB%' THEN 'WEB'
        WHEN m.mkt_channel_medium LIKE 'Estudio Inmueble%' THEN 'Estudio Inmueble'
        WHEN m.mkt_channel_medium IN ('lead_forms Paid', 'lead_forms Direct') OR m.mkt_channel_medium LIKE 'Lead Forms%' THEN 'lead_forms'
      END AS fuente,
      ROUND(SUM(i.spend), 0) AS spend
    FROM `papyrus-data.habi_wh_bi.resumen_inversiones_mkt_co` i
    JOIN utm_dedup_camp m ON i.campana = m.mkt_campaign_name
    WHERE i.date >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 140 DAY), ISOWEEK)
      AND i.date < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
      AND m.mkt_channel_medium IS NOT NULL
      AND m.mkt_platform IS NOT NULL
      AND m.mkt_platform != ''
    GROUP BY 1, 2, 3, 4
    HAVING fuente IS NOT NULL
  ),
  weeks_combos AS (
    SELECT week, platform, channel, fuente FROM reg_agg
    UNION DISTINCT SELECT week, platform, channel, fuente FROM cal_agg
    UNION DISTINCT SELECT week, platform, channel, fuente FROM asg_agg
    UNION DISTINCT SELECT week, platform, channel, fuente FROM spend_agg
  )

SELECT
  CAST(wc.week AS STRING) AS week_start,
  wc.platform,
  wc.channel,
  wc.fuente,
  COALESCE(r.n, 0)        AS reg,
  COALESCE(c.n, 0)        AS cal,
  COALESCE(a.n, 0)        AS asg,
  COALESCE(s.spend, NULL) AS spend
FROM weeks_combos wc
LEFT JOIN reg_agg   r USING (week, platform, channel, fuente)
LEFT JOIN cal_agg   c USING (week, platform, channel, fuente)
LEFT JOIN asg_agg   a USING (week, platform, channel, fuente)
LEFT JOIN spend_agg s USING (week, platform, channel, fuente)
ORDER BY week_start, platform, channel
