-- Funnel Sellers (CO + MX) — Cohort + Events
-- Genera un único dataset con ambas vistas:
--   Cohort: agrupa por fecha_creacion del lead, cuenta si EN CUALQUIER MOMENTO llegó al stage
--   Events: agrupa por fecha del primer evento del stage (primera ocurrencia)
-- Ambas vistas comparten el mismo período P y el mismo t (Registros, por fecha_creacion).
-- El dashboard alterna entre modos con un selector; el % siempre se calcula como stage/t.
--
-- Campos por fila:
--   g, c, f, fn, p, t
--   Cohort:  cal, asg, cit, vis, apr, acp, cie
--   Events:  e_cal, e_asg, e_cit, e_vis, e_apr, e_acp, e_cie
--
-- Calificados (cal): basado en HISTÓRICO de estados, primera entrada a estado_id IN (20, 63)
--   CO: sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2 (estado_id, negocio_id)
--   MX: sellers-main-prod.mx_rds_staging.habi_db_history_state           (state_id, deal_id)
--
-- Stages: primera ocurrencia en las tablas de funnel events
--   CO: papyrus-data.habi_wh_bi.funnel_diarios_col
--   MX: sellers-main-prod.bi_mx.seguimiento_funnel_mex
--
-- Filtros: nid NOT NULL, fuente_id en los 6 relevantes por país, fecha_creacion < hoy
-- D/W/C/Q: últimos 25 períodos (dentro de la ventana, incluye el actual en curso)
-- M/Y: historia completa

WITH funnel_reach AS (
  SELECT 'Colombia' AS c, nid,
    MIN(IF(valor = 'Primer_asigancion', DATE(fecha), NULL)) AS asg_date,
    MIN(IF(valor = 'Cita agendada', DATE(fecha), NULL)) AS cit_date,
    MIN(IF(valor = 'Visita efectuada', DATE(fecha), NULL)) AS vis_date,
    MIN(IF(valor IN ('Aprobado', 'inmueble aprobado'), DATE(fecha), NULL)) AS apr_date,
    MIN(IF(valor IN ('Aceptó Oferta - Pendiente firma', 'Aceptó Oferta - aplazado'), DATE(fecha), NULL)) AS acp_date,
    MIN(IF(valor = 'Cierre - Comprado', DATE(fecha), NULL)) AS cie_date
  FROM `papyrus-data.habi_wh_bi.funnel_diarios_col` WHERE nid IS NOT NULL GROUP BY c, nid

  UNION ALL

  SELECT 'México' AS c, nid,
    MIN(IF(valor = 'Primer asignacion', DATE(fecha), NULL)) AS asg_date,
    MIN(IF(valor IN ('Cita Agendada', 'Cita Agendada (hubspot)'), DATE(fecha), NULL)) AS cit_date,
    MIN(IF(valor IN ('Visita Efectuada', 'Visita Efectuada (hubspot)'), DATE(fecha), NULL)) AS vis_date,
    MIN(IF(valor IN ('Aprobado General', 'Primer inmueble aprobado'), DATE(fecha), NULL)) AS apr_date,
    MIN(IF(valor = 'Acepto Oferta - Pendiente firma', DATE(fecha), NULL)) AS acp_date,
    MIN(IF(valor = 'Cierre - Comprado', DATE(fecha), NULL)) AS cie_date
  FROM `sellers-main-prod.bi_mx.seguimiento_funnel_mex` WHERE nid IS NOT NULL GROUP BY c, nid
),

cal_events AS (
  SELECT 'Colombia' AS c, negocio_id AS business_id, MIN(DATE(fecha_actualizacion)) AS cal_date
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
  WHERE estado_id IN (20, 63) AND negocio_id IS NOT NULL
  GROUP BY c, business_id

  UNION ALL

  SELECT 'México' AS c, deal_id AS business_id, MIN(DATE(date_create)) AS cal_date
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state`
  WHERE state_id IN (20, 63) AND deal_id IS NOT NULL
  GROUP BY c, business_id
),

-- Asignados oficiales (data mart de marketing, fuente única para WBR)
asg_oficial AS (
  SELECT
    IF(LOWER(pais) = 'colombia', 'Colombia', 'México') AS c,
    nid,
    MIN(DATE(dia)) AS oas_date
  FROM `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart`
  WHERE nid IS NOT NULL
  GROUP BY c, nid
),

base AS (
  SELECT 'Colombia' AS c, tig.nid, tig.fuente_id, tig.fuente, DATE(tig.fecha_creacion) AS fecha,
    ce.cal_date, fr.asg_date, fr.cit_date, fr.vis_date, fr.apr_date, fr.acp_date, fr.cie_date,
    ao.oas_date
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` tig
  LEFT JOIN funnel_reach fr ON fr.c = 'Colombia' AND fr.nid = tig.nid
  LEFT JOIN cal_events ce ON ce.c = 'Colombia' AND ce.business_id = tig.negocio_id
  LEFT JOIN asg_oficial ao ON ao.c = 'Colombia' AND ao.nid = tig.nid
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 20, 35, 39, 47)

  UNION ALL

  SELECT 'México' AS c, tig.nid, tig.fuente_id, tig.fuente, DATE(tig.fecha_creacion) AS fecha,
    ce.cal_date, fr.asg_date, fr.cit_date, fr.vis_date, fr.apr_date, fr.acp_date, fr.cie_date,
    ao.oas_date
  FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` tig
  LEFT JOIN funnel_reach fr ON fr.c = 'México' AND fr.nid = tig.nid
  LEFT JOIN cal_events ce ON ce.c = 'México' AND ce.business_id = tig.id_negocio
  LEFT JOIN asg_oficial ao ON ao.c = 'México' AND ao.nid = tig.nid
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 35, 39, 46, 47)
),

-- Events unpivoteados: una fila por (nid, stage, fecha_evento) para agregar por fecha de evento
events_raw AS (
  SELECT c, nid, fuente_id, fuente, 'cal' stage, cal_date ev_date FROM base WHERE cal_date IS NOT NULL
  UNION ALL SELECT c, nid, fuente_id, fuente, 'asg', asg_date FROM base WHERE asg_date IS NOT NULL
  UNION ALL SELECT c, nid, fuente_id, fuente, 'oas', oas_date FROM base WHERE oas_date IS NOT NULL
  UNION ALL SELECT c, nid, fuente_id, fuente, 'cit', cit_date FROM base WHERE cit_date IS NOT NULL
  UNION ALL SELECT c, nid, fuente_id, fuente, 'vis', vis_date FROM base WHERE vis_date IS NOT NULL
  UNION ALL SELECT c, nid, fuente_id, fuente, 'apr', apr_date FROM base WHERE apr_date IS NOT NULL
  UNION ALL SELECT c, nid, fuente_id, fuente, 'acp', acp_date FROM base WHERE acp_date IS NOT NULL
  UNION ALL SELECT c, nid, fuente_id, fuente, 'cie', cie_date FROM base WHERE cie_date IS NOT NULL
),

day_periods AS (SELECT DISTINCT fecha FROM base ORDER BY fecha DESC LIMIT 25),
week_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, ISOWEEK) p FROM base ORDER BY p DESC LIMIT 25),
comm_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, WEEK(WEDNESDAY)) p FROM base ORDER BY p DESC LIMIT 25),
quarter_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, QUARTER) p FROM base ORDER BY p DESC LIMIT 25),

-- ======================== COHORT aggregations (group by fecha_creacion) ========================
cohort_daily AS (
  SELECT 'D' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(fecha AS STRING) p,
    COUNT(*) tr,
    COUNT(DISTINCT nid) t,
    COUNT(DISTINCT IF(cal_date IS NOT NULL, nid, NULL)) cal,
    COUNT(DISTINCT IF(asg_date IS NOT NULL, nid, NULL)) asg,
    COUNT(DISTINCT IF(oas_date IS NOT NULL, nid, NULL)) oas,
    COUNT(DISTINCT IF(cit_date IS NOT NULL, nid, NULL)) cit,
    COUNT(DISTINCT IF(vis_date IS NOT NULL, nid, NULL)) vis,
    COUNT(DISTINCT IF(apr_date IS NOT NULL, nid, NULL)) apr,
    COUNT(DISTINCT IF(acp_date IS NOT NULL, nid, NULL)) acp,
    COUNT(DISTINCT IF(cie_date IS NOT NULL, nid, NULL)) cie
  FROM base WHERE fecha IN (SELECT fecha FROM day_periods) GROUP BY c, f, p
),
cohort_weekly AS (
  SELECT 'W' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(fecha, ISOWEEK) AS STRING) p,
    COUNT(*) tr,
    COUNT(DISTINCT nid) t,
    COUNT(DISTINCT IF(cal_date IS NOT NULL, nid, NULL)) cal,
    COUNT(DISTINCT IF(asg_date IS NOT NULL, nid, NULL)) asg,
    COUNT(DISTINCT IF(oas_date IS NOT NULL, nid, NULL)) oas,
    COUNT(DISTINCT IF(cit_date IS NOT NULL, nid, NULL)) cit,
    COUNT(DISTINCT IF(vis_date IS NOT NULL, nid, NULL)) vis,
    COUNT(DISTINCT IF(apr_date IS NOT NULL, nid, NULL)) apr,
    COUNT(DISTINCT IF(acp_date IS NOT NULL, nid, NULL)) acp,
    COUNT(DISTINCT IF(cie_date IS NOT NULL, nid, NULL)) cie
  FROM base WHERE DATE_TRUNC(fecha, ISOWEEK) IN (SELECT p FROM week_periods) GROUP BY c, f, p
),
cohort_commercial AS (
  SELECT 'C' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(fecha, WEEK(WEDNESDAY)) AS STRING) p,
    COUNT(*) tr,
    COUNT(DISTINCT nid) t,
    COUNT(DISTINCT IF(cal_date IS NOT NULL, nid, NULL)) cal,
    COUNT(DISTINCT IF(asg_date IS NOT NULL, nid, NULL)) asg,
    COUNT(DISTINCT IF(oas_date IS NOT NULL, nid, NULL)) oas,
    COUNT(DISTINCT IF(cit_date IS NOT NULL, nid, NULL)) cit,
    COUNT(DISTINCT IF(vis_date IS NOT NULL, nid, NULL)) vis,
    COUNT(DISTINCT IF(apr_date IS NOT NULL, nid, NULL)) apr,
    COUNT(DISTINCT IF(acp_date IS NOT NULL, nid, NULL)) acp,
    COUNT(DISTINCT IF(cie_date IS NOT NULL, nid, NULL)) cie
  FROM base WHERE DATE_TRUNC(fecha, WEEK(WEDNESDAY)) IN (SELECT p FROM comm_periods) GROUP BY c, f, p
),
cohort_monthly AS (
  SELECT 'M' g, c, fuente_id f, ANY_VALUE(fuente) fn, FORMAT_DATE('%Y-%m', fecha) p,
    COUNT(*) tr,
    COUNT(DISTINCT nid) t,
    COUNT(DISTINCT IF(cal_date IS NOT NULL, nid, NULL)) cal,
    COUNT(DISTINCT IF(asg_date IS NOT NULL, nid, NULL)) asg,
    COUNT(DISTINCT IF(oas_date IS NOT NULL, nid, NULL)) oas,
    COUNT(DISTINCT IF(cit_date IS NOT NULL, nid, NULL)) cit,
    COUNT(DISTINCT IF(vis_date IS NOT NULL, nid, NULL)) vis,
    COUNT(DISTINCT IF(apr_date IS NOT NULL, nid, NULL)) apr,
    COUNT(DISTINCT IF(acp_date IS NOT NULL, nid, NULL)) acp,
    COUNT(DISTINCT IF(cie_date IS NOT NULL, nid, NULL)) cie
  FROM base GROUP BY c, f, p
),
cohort_quarterly AS (
  SELECT 'Q' g, c, fuente_id f, ANY_VALUE(fuente) fn,
    CONCAT(CAST(EXTRACT(YEAR FROM fecha) AS STRING), '-Q', CAST(EXTRACT(QUARTER FROM fecha) AS STRING)) p,
    COUNT(*) tr,
    COUNT(DISTINCT nid) t,
    COUNT(DISTINCT IF(cal_date IS NOT NULL, nid, NULL)) cal,
    COUNT(DISTINCT IF(asg_date IS NOT NULL, nid, NULL)) asg,
    COUNT(DISTINCT IF(oas_date IS NOT NULL, nid, NULL)) oas,
    COUNT(DISTINCT IF(cit_date IS NOT NULL, nid, NULL)) cit,
    COUNT(DISTINCT IF(vis_date IS NOT NULL, nid, NULL)) vis,
    COUNT(DISTINCT IF(apr_date IS NOT NULL, nid, NULL)) apr,
    COUNT(DISTINCT IF(acp_date IS NOT NULL, nid, NULL)) acp,
    COUNT(DISTINCT IF(cie_date IS NOT NULL, nid, NULL)) cie
  FROM base WHERE DATE_TRUNC(fecha, QUARTER) IN (SELECT p FROM quarter_periods) GROUP BY c, f, p
),
cohort_yearly AS (
  SELECT 'Y' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(EXTRACT(YEAR FROM fecha) AS STRING) p,
    COUNT(*) tr,
    COUNT(DISTINCT nid) t,
    COUNT(DISTINCT IF(cal_date IS NOT NULL, nid, NULL)) cal,
    COUNT(DISTINCT IF(asg_date IS NOT NULL, nid, NULL)) asg,
    COUNT(DISTINCT IF(oas_date IS NOT NULL, nid, NULL)) oas,
    COUNT(DISTINCT IF(cit_date IS NOT NULL, nid, NULL)) cit,
    COUNT(DISTINCT IF(vis_date IS NOT NULL, nid, NULL)) vis,
    COUNT(DISTINCT IF(apr_date IS NOT NULL, nid, NULL)) apr,
    COUNT(DISTINCT IF(acp_date IS NOT NULL, nid, NULL)) acp,
    COUNT(DISTINCT IF(cie_date IS NOT NULL, nid, NULL)) cie
  FROM base GROUP BY c, f, p
),

-- ======================== EVENTS aggregations (group by event date) ========================
events_daily AS (
  SELECT 'D' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(ev_date AS STRING) p,
    COUNT(DISTINCT IF(stage='cal', nid, NULL)) e_cal,
    COUNT(DISTINCT IF(stage='asg', nid, NULL)) e_asg,
    COUNT(DISTINCT IF(stage='oas', nid, NULL)) e_oas,
    COUNT(DISTINCT IF(stage='cit', nid, NULL)) e_cit,
    COUNT(DISTINCT IF(stage='vis', nid, NULL)) e_vis,
    COUNT(DISTINCT IF(stage='apr', nid, NULL)) e_apr,
    COUNT(DISTINCT IF(stage='acp', nid, NULL)) e_acp,
    COUNT(DISTINCT IF(stage='cie', nid, NULL)) e_cie
  FROM events_raw WHERE ev_date IN (SELECT fecha FROM day_periods) GROUP BY c, f, p
),
events_weekly AS (
  SELECT 'W' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(ev_date, ISOWEEK) AS STRING) p,
    COUNT(DISTINCT IF(stage='cal', nid, NULL)) e_cal,
    COUNT(DISTINCT IF(stage='asg', nid, NULL)) e_asg,
    COUNT(DISTINCT IF(stage='oas', nid, NULL)) e_oas,
    COUNT(DISTINCT IF(stage='cit', nid, NULL)) e_cit,
    COUNT(DISTINCT IF(stage='vis', nid, NULL)) e_vis,
    COUNT(DISTINCT IF(stage='apr', nid, NULL)) e_apr,
    COUNT(DISTINCT IF(stage='acp', nid, NULL)) e_acp,
    COUNT(DISTINCT IF(stage='cie', nid, NULL)) e_cie
  FROM events_raw WHERE DATE_TRUNC(ev_date, ISOWEEK) IN (SELECT p FROM week_periods) GROUP BY c, f, p
),
events_commercial AS (
  SELECT 'C' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(ev_date, WEEK(WEDNESDAY)) AS STRING) p,
    COUNT(DISTINCT IF(stage='cal', nid, NULL)) e_cal,
    COUNT(DISTINCT IF(stage='asg', nid, NULL)) e_asg,
    COUNT(DISTINCT IF(stage='oas', nid, NULL)) e_oas,
    COUNT(DISTINCT IF(stage='cit', nid, NULL)) e_cit,
    COUNT(DISTINCT IF(stage='vis', nid, NULL)) e_vis,
    COUNT(DISTINCT IF(stage='apr', nid, NULL)) e_apr,
    COUNT(DISTINCT IF(stage='acp', nid, NULL)) e_acp,
    COUNT(DISTINCT IF(stage='cie', nid, NULL)) e_cie
  FROM events_raw WHERE DATE_TRUNC(ev_date, WEEK(WEDNESDAY)) IN (SELECT p FROM comm_periods) GROUP BY c, f, p
),
events_monthly AS (
  SELECT 'M' g, c, fuente_id f, ANY_VALUE(fuente) fn, FORMAT_DATE('%Y-%m', ev_date) p,
    COUNT(DISTINCT IF(stage='cal', nid, NULL)) e_cal,
    COUNT(DISTINCT IF(stage='asg', nid, NULL)) e_asg,
    COUNT(DISTINCT IF(stage='oas', nid, NULL)) e_oas,
    COUNT(DISTINCT IF(stage='cit', nid, NULL)) e_cit,
    COUNT(DISTINCT IF(stage='vis', nid, NULL)) e_vis,
    COUNT(DISTINCT IF(stage='apr', nid, NULL)) e_apr,
    COUNT(DISTINCT IF(stage='acp', nid, NULL)) e_acp,
    COUNT(DISTINCT IF(stage='cie', nid, NULL)) e_cie
  FROM events_raw GROUP BY c, f, p
),
events_quarterly AS (
  SELECT 'Q' g, c, fuente_id f, ANY_VALUE(fuente) fn,
    CONCAT(CAST(EXTRACT(YEAR FROM ev_date) AS STRING), '-Q', CAST(EXTRACT(QUARTER FROM ev_date) AS STRING)) p,
    COUNT(DISTINCT IF(stage='cal', nid, NULL)) e_cal,
    COUNT(DISTINCT IF(stage='asg', nid, NULL)) e_asg,
    COUNT(DISTINCT IF(stage='oas', nid, NULL)) e_oas,
    COUNT(DISTINCT IF(stage='cit', nid, NULL)) e_cit,
    COUNT(DISTINCT IF(stage='vis', nid, NULL)) e_vis,
    COUNT(DISTINCT IF(stage='apr', nid, NULL)) e_apr,
    COUNT(DISTINCT IF(stage='acp', nid, NULL)) e_acp,
    COUNT(DISTINCT IF(stage='cie', nid, NULL)) e_cie
  FROM events_raw WHERE DATE_TRUNC(ev_date, QUARTER) IN (SELECT p FROM quarter_periods) GROUP BY c, f, p
),
events_yearly AS (
  SELECT 'Y' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(EXTRACT(YEAR FROM ev_date) AS STRING) p,
    COUNT(DISTINCT IF(stage='cal', nid, NULL)) e_cal,
    COUNT(DISTINCT IF(stage='asg', nid, NULL)) e_asg,
    COUNT(DISTINCT IF(stage='oas', nid, NULL)) e_oas,
    COUNT(DISTINCT IF(stage='cit', nid, NULL)) e_cit,
    COUNT(DISTINCT IF(stage='vis', nid, NULL)) e_vis,
    COUNT(DISTINCT IF(stage='apr', nid, NULL)) e_apr,
    COUNT(DISTINCT IF(stage='acp', nid, NULL)) e_acp,
    COUNT(DISTINCT IF(stage='cie', nid, NULL)) e_cie
  FROM events_raw GROUP BY c, f, p
),

cohort_all AS (
  SELECT * FROM cohort_daily
  UNION ALL SELECT * FROM cohort_weekly
  UNION ALL SELECT * FROM cohort_commercial
  UNION ALL SELECT * FROM cohort_monthly
  UNION ALL SELECT * FROM cohort_quarterly
  UNION ALL SELECT * FROM cohort_yearly
),
events_all AS (
  SELECT * FROM events_daily
  UNION ALL SELECT * FROM events_weekly
  UNION ALL SELECT * FROM events_commercial
  UNION ALL SELECT * FROM events_monthly
  UNION ALL SELECT * FROM events_quarterly
  UNION ALL SELECT * FROM events_yearly
)

SELECT
  COALESCE(co.g, ev.g) g,
  COALESCE(co.c, ev.c) c,
  COALESCE(co.f, ev.f) f,
  COALESCE(co.fn, ev.fn) fn,
  COALESCE(co.p, ev.p) p,
  COALESCE(co.tr, 0) tr,
  COALESCE(co.t, 0) t,
  COALESCE(co.cal, 0) cal,
  COALESCE(co.asg, 0) asg,
  COALESCE(co.oas, 0) oas,
  COALESCE(co.cit, 0) cit,
  COALESCE(co.vis, 0) vis,
  COALESCE(co.apr, 0) apr,
  COALESCE(co.acp, 0) acp,
  COALESCE(co.cie, 0) cie,
  COALESCE(ev.e_cal, 0) e_cal,
  COALESCE(ev.e_asg, 0) e_asg,
  COALESCE(ev.e_oas, 0) e_oas,
  COALESCE(ev.e_cit, 0) e_cit,
  COALESCE(ev.e_vis, 0) e_vis,
  COALESCE(ev.e_apr, 0) e_apr,
  COALESCE(ev.e_acp, 0) e_acp,
  COALESCE(ev.e_cie, 0) e_cie
FROM cohort_all co
FULL OUTER JOIN events_all ev USING (g, c, f, p)
ORDER BY g, c, f, p
