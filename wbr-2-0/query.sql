-- WBR 2.0 — Métricas semanales por fuente (CO)
-- Output: one row per (week_start, fuente) with reg, cal, asg, spend.
-- Window: últimas 14 semanas ISO (lun-dom), excluye semana actual.
-- Volumes are EVENT-based (each metric counted in the week it happened).

WITH
  leads AS (
    SELECT g.negocio_id, g.fuente_id, DATE(g.fecha_creacion) AS reg_date
    FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` g
    WHERE g.fuente_id IN (3, 7, 20, 35, 39, 47)
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
    SELECT DATE_TRUNC(reg_date, ISOWEEK) AS week, fuente_id, COUNT(*) AS n
    FROM leads
    WHERE reg_date >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 140 DAY), ISOWEEK)
      AND reg_date < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
    GROUP BY 1, 2
  ),
  cal_agg AS (
    SELECT DATE_TRUNC(DATE(c.cal_ts), ISOWEEK) AS week, l.fuente_id, COUNT(*) AS n
    FROM cal c
    JOIN leads l ON l.negocio_id = c.negocio_id
    GROUP BY 1, 2
  ),
  asg_agg AS (
    SELECT DATE_TRUNC(a.dia, ISOWEEK) AS week, a.fuente_id_tig AS fuente_id, COUNT(*) AS n
    FROM `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart` a
    WHERE a.pais = 'colombia'
      AND a.fuente_id_tig IN (3, 7, 20, 35, 39, 47)
      AND a.dia >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 140 DAY), ISOWEEK)
      AND a.dia < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
    GROUP BY 1, 2
  ),
  -- Spend mapped to fuente via canal_adquisicion (Brand/Otro dropped → no fuente)
  spend_agg AS (
    SELECT
      DATE_TRUNC(i.date, ISOWEEK) AS week,
      CASE
        WHEN i.canal_adquisicion = 'Web' THEN 3
        WHEN i.canal_adquisicion IN ('Habimetro', 'Calculadora de gastos') THEN 7
        WHEN i.canal_adquisicion = 'Lead Form' THEN 47
      END AS fuente_id,
      ROUND(SUM(i.spend), 0) AS spend
    FROM `papyrus-data.habi_wh_bi.resumen_inversiones_mkt_co` i
    WHERE i.date >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 140 DAY), ISOWEEK)
      AND i.date < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
    GROUP BY 1, 2
    HAVING fuente_id IS NOT NULL
  ),
  weeks_fuentes AS (
    SELECT week, fuente_id FROM reg_agg
    UNION DISTINCT SELECT week, fuente_id FROM cal_agg
    UNION DISTINCT SELECT week, fuente_id FROM asg_agg
    UNION DISTINCT SELECT week, fuente_id FROM spend_agg
  )

SELECT
  CAST(wf.week AS STRING) AS week_start,
  CASE wf.fuente_id
    WHEN 3  THEN 'WEB'
    WHEN 7  THEN 'Estudio Inmueble'
    WHEN 20 THEN 'CRM'
    WHEN 35 THEN 'Comercial'
    WHEN 39 THEN 'Broker'
    WHEN 47 THEN 'lead_forms'
  END AS fuente,
  COALESCE(r.n, 0)        AS reg,
  COALESCE(c.n, 0)        AS cal,
  COALESCE(a.n, 0)        AS asg,
  COALESCE(s.spend, NULL) AS spend
FROM weeks_fuentes wf
LEFT JOIN reg_agg   r USING (week, fuente_id)
LEFT JOIN cal_agg   c USING (week, fuente_id)
LEFT JOIN asg_agg   a USING (week, fuente_id)
LEFT JOIN spend_agg s USING (week, fuente_id)
ORDER BY week_start, fuente
