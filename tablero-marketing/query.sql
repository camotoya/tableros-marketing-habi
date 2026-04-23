-- Funnel Sellers (CO + MX) — Cohort + Events con Calificados MM e Inmo
-- Campos por fila: g, c, f, fn, p, tr, t, cal_mm, cal_inmo, e_cal_mm, e_cal_inmo
--   tr          = Registros totales (COUNT(*), por fecha_creacion, ambos modos)
--   t           = Registros con NID (COUNT DISTINCT nid, por fecha_creacion)
--   cal_mm      = Cohort: leads creados en el período que alguna vez fueron calificados MM
--   cal_inmo    = Cohort: leads creados en el período que alguna vez fueron calificados Inmo
--   e_cal_mm    = Events: primera entrada a calificado MM que ocurrió en el período
--   e_cal_inmo  = Events: primera entrada a calificado Inmo que ocurrió en el período
-- Cohort agrupa por fecha_creacion; Events agrupa por fecha del evento.
-- Calificado MM: estado_id IN (20, 63). Calificado Inmo: state_id = 20 (estados terminales).

WITH base AS (
  SELECT 'Colombia' AS c, tig.nid, tig.fuente_id, tig.fuente,
    DATE(tig.fecha_creacion) AS fecha, tig.negocio_id AS biz_id
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` tig
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 20, 35, 39, 47)

  UNION ALL

  SELECT 'México' AS c, tig.nid, tig.fuente_id, tig.fuente,
    DATE(tig.fecha_creacion) AS fecha, tig.id_negocio AS biz_id
  FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` tig
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 35, 39, 46, 47)
),

cal_mm_dates AS (
  SELECT 'Colombia' AS c, negocio_id AS biz_id, MIN(DATE(fecha_actualizacion)) AS ev_date
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
  WHERE estado_id IN (20, 63) AND negocio_id IS NOT NULL
  GROUP BY c, biz_id

  UNION ALL

  SELECT 'México' AS c, deal_id AS biz_id, MIN(DATE(date_create)) AS ev_date
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state`
  WHERE state_id IN (20, 63) AND deal_id IS NOT NULL
  GROUP BY c, biz_id
),

cal_inmo_dates AS (
  SELECT 'Colombia' AS c, deal_id AS biz_id, MIN(DATE(date_create)) AS ev_date
  FROM `sellers-main-prod.co_rds_staging.habi_db_history_state_real_estate`
  WHERE state_id = 20 AND deal_id IS NOT NULL
  GROUP BY c, biz_id

  UNION ALL

  SELECT 'México' AS c, deal_id AS biz_id, MIN(DATE(date_create)) AS ev_date
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state_real_estate`
  WHERE state_id = 20 AND deal_id IS NOT NULL
  GROUP BY c, biz_id
),

-- Estado actual del lead (MM) en OLTP, por país
current_state AS (
  SELECT 'Colombia' AS c, id AS biz_id, last_estado_id AS st
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_negocio_inmueble`
  UNION ALL
  SELECT 'México' AS c, id AS biz_id, last_state_id AS st
  FROM `sellers-main-prod.mx_rds_staging.habi_db_property_deal`
),

enriched AS (
  SELECT b.c, b.nid, b.fuente_id, b.fuente, b.fecha,
    mc.ev_date AS cal_mm_date,
    ic.ev_date AS cal_inmo_date,
    cs.st AS cur_state
  FROM base b
  LEFT JOIN cal_mm_dates mc ON mc.c = b.c AND mc.biz_id = b.biz_id
  LEFT JOIN cal_inmo_dates ic ON ic.c = b.c AND ic.biz_id = b.biz_id
  LEFT JOIN current_state cs ON cs.c = b.c AND cs.biz_id = b.biz_id
),

events_long AS (
  SELECT c, nid, fuente_id, fuente, 'mm' AS stage, cal_mm_date AS ev_date,
    (cal_inmo_date IS NULL) AS no_inmo
    FROM enriched WHERE cal_mm_date IS NOT NULL
  UNION ALL
  SELECT c, nid, fuente_id, fuente, 'inmo', cal_inmo_date, FALSE
    FROM enriched WHERE cal_inmo_date IS NOT NULL
),

day_periods AS (SELECT DISTINCT fecha FROM enriched ORDER BY fecha DESC LIMIT 25),
week_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, ISOWEEK) p FROM enriched ORDER BY p DESC LIMIT 25),
comm_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, WEEK(WEDNESDAY)) p FROM enriched ORDER BY p DESC LIMIT 25),
month_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, MONTH) p FROM enriched ORDER BY p DESC LIMIT 25),
quarter_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, QUARTER) p FROM enriched ORDER BY p DESC LIMIT 25),

-- COHORT (group by fecha_creacion)
cohort_daily AS (
  SELECT 'D' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(fecha AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(cal_mm_date IS NOT NULL) cal_mm,
    COUNTIF(cal_inmo_date IS NOT NULL) cal_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cal_inmo_date IS NULL) cal_mm_no_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state = 1) cal_mm_dup,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state IN (3,10,16,33,38,55,56,61,64)) cal_mm_desc,
    COUNTIF(cur_state = 7) incomp,
    COUNTIF(cur_state = 1) dup
  FROM enriched WHERE fecha IN (SELECT fecha FROM day_periods) GROUP BY c, f, p
),
cohort_weekly AS (
  SELECT 'W' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(fecha, ISOWEEK) AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(cal_mm_date IS NOT NULL) cal_mm,
    COUNTIF(cal_inmo_date IS NOT NULL) cal_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cal_inmo_date IS NULL) cal_mm_no_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state = 1) cal_mm_dup,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state IN (3,10,16,33,38,55,56,61,64)) cal_mm_desc,
    COUNTIF(cur_state = 7) incomp,
    COUNTIF(cur_state = 1) dup
  FROM enriched WHERE DATE_TRUNC(fecha, ISOWEEK) IN (SELECT p FROM week_periods) GROUP BY c, f, p
),
cohort_commercial AS (
  SELECT 'C' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(fecha, WEEK(WEDNESDAY)) AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(cal_mm_date IS NOT NULL) cal_mm,
    COUNTIF(cal_inmo_date IS NOT NULL) cal_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cal_inmo_date IS NULL) cal_mm_no_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state = 1) cal_mm_dup,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state IN (3,10,16,33,38,55,56,61,64)) cal_mm_desc,
    COUNTIF(cur_state = 7) incomp,
    COUNTIF(cur_state = 1) dup
  FROM enriched WHERE DATE_TRUNC(fecha, WEEK(WEDNESDAY)) IN (SELECT p FROM comm_periods) GROUP BY c, f, p
),
cohort_monthly AS (
  SELECT 'M' g, c, fuente_id f, ANY_VALUE(fuente) fn, FORMAT_DATE('%Y-%m', fecha) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(cal_mm_date IS NOT NULL) cal_mm,
    COUNTIF(cal_inmo_date IS NOT NULL) cal_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cal_inmo_date IS NULL) cal_mm_no_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state = 1) cal_mm_dup,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state IN (3,10,16,33,38,55,56,61,64)) cal_mm_desc,
    COUNTIF(cur_state = 7) incomp,
    COUNTIF(cur_state = 1) dup
  FROM enriched WHERE DATE_TRUNC(fecha, MONTH) IN (SELECT p FROM month_periods) GROUP BY c, f, p
),
cohort_quarterly AS (
  SELECT 'Q' g, c, fuente_id f, ANY_VALUE(fuente) fn,
    CONCAT(CAST(EXTRACT(YEAR FROM fecha) AS STRING), '-Q', CAST(EXTRACT(QUARTER FROM fecha) AS STRING)) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(cal_mm_date IS NOT NULL) cal_mm,
    COUNTIF(cal_inmo_date IS NOT NULL) cal_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cal_inmo_date IS NULL) cal_mm_no_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state = 1) cal_mm_dup,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state IN (3,10,16,33,38,55,56,61,64)) cal_mm_desc,
    COUNTIF(cur_state = 7) incomp,
    COUNTIF(cur_state = 1) dup
  FROM enriched WHERE DATE_TRUNC(fecha, QUARTER) IN (SELECT p FROM quarter_periods) GROUP BY c, f, p
),
cohort_yearly AS (
  SELECT 'Y' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(EXTRACT(YEAR FROM fecha) AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(cal_mm_date IS NOT NULL) cal_mm,
    COUNTIF(cal_inmo_date IS NOT NULL) cal_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cal_inmo_date IS NULL) cal_mm_no_inmo,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state = 1) cal_mm_dup,
    COUNTIF(cal_mm_date IS NOT NULL AND cur_state IN (3,10,16,33,38,55,56,61,64)) cal_mm_desc,
    COUNTIF(cur_state = 7) incomp,
    COUNTIF(cur_state = 1) dup
  FROM enriched GROUP BY c, f, p
),

-- EVENTS (group by ev_date = primera entrada al estado calificado)
events_daily AS (
  SELECT 'D' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(ev_date AS STRING) p,
    COUNTIF(stage='mm') e_cal_mm, COUNTIF(stage='inmo') e_cal_inmo,
    COUNTIF(stage='mm' AND no_inmo) e_cal_mm_no_inmo
  FROM events_long WHERE ev_date IN (SELECT fecha FROM day_periods) GROUP BY c, f, p
),
events_weekly AS (
  SELECT 'W' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(ev_date, ISOWEEK) AS STRING) p,
    COUNTIF(stage='mm') e_cal_mm, COUNTIF(stage='inmo') e_cal_inmo,
    COUNTIF(stage='mm' AND no_inmo) e_cal_mm_no_inmo
  FROM events_long WHERE DATE_TRUNC(ev_date, ISOWEEK) IN (SELECT p FROM week_periods) GROUP BY c, f, p
),
events_commercial AS (
  SELECT 'C' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(ev_date, WEEK(WEDNESDAY)) AS STRING) p,
    COUNTIF(stage='mm') e_cal_mm, COUNTIF(stage='inmo') e_cal_inmo,
    COUNTIF(stage='mm' AND no_inmo) e_cal_mm_no_inmo
  FROM events_long WHERE DATE_TRUNC(ev_date, WEEK(WEDNESDAY)) IN (SELECT p FROM comm_periods) GROUP BY c, f, p
),
events_monthly AS (
  SELECT 'M' g, c, fuente_id f, ANY_VALUE(fuente) fn, FORMAT_DATE('%Y-%m', ev_date) p,
    COUNTIF(stage='mm') e_cal_mm, COUNTIF(stage='inmo') e_cal_inmo,
    COUNTIF(stage='mm' AND no_inmo) e_cal_mm_no_inmo
  FROM events_long WHERE DATE_TRUNC(ev_date, MONTH) IN (SELECT p FROM month_periods) GROUP BY c, f, p
),
events_quarterly AS (
  SELECT 'Q' g, c, fuente_id f, ANY_VALUE(fuente) fn,
    CONCAT(CAST(EXTRACT(YEAR FROM ev_date) AS STRING), '-Q', CAST(EXTRACT(QUARTER FROM ev_date) AS STRING)) p,
    COUNTIF(stage='mm') e_cal_mm, COUNTIF(stage='inmo') e_cal_inmo,
    COUNTIF(stage='mm' AND no_inmo) e_cal_mm_no_inmo
  FROM events_long WHERE DATE_TRUNC(ev_date, QUARTER) IN (SELECT p FROM quarter_periods) GROUP BY c, f, p
),
events_yearly AS (
  SELECT 'Y' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(EXTRACT(YEAR FROM ev_date) AS STRING) p,
    COUNTIF(stage='mm') e_cal_mm, COUNTIF(stage='inmo') e_cal_inmo,
    COUNTIF(stage='mm' AND no_inmo) e_cal_mm_no_inmo
  FROM events_long GROUP BY c, f, p
),

cohort_all AS (
  SELECT * FROM cohort_daily UNION ALL SELECT * FROM cohort_weekly UNION ALL SELECT * FROM cohort_commercial
  UNION ALL SELECT * FROM cohort_monthly UNION ALL SELECT * FROM cohort_quarterly UNION ALL SELECT * FROM cohort_yearly
),
events_all AS (
  SELECT * FROM events_daily UNION ALL SELECT * FROM events_weekly UNION ALL SELECT * FROM events_commercial
  UNION ALL SELECT * FROM events_monthly UNION ALL SELECT * FROM events_quarterly UNION ALL SELECT * FROM events_yearly
)

SELECT
  COALESCE(co.g, ev.g) g,
  COALESCE(co.c, ev.c) c,
  COALESCE(co.f, ev.f) f,
  COALESCE(co.fn, ev.fn) fn,
  COALESCE(co.p, ev.p) p,
  COALESCE(co.tr, 0) tr,
  COALESCE(co.t, 0) t,
  COALESCE(co.cal_mm, 0) cal_mm,
  COALESCE(co.cal_inmo, 0) cal_inmo,
  COALESCE(co.cal_mm_no_inmo, 0) cal_mm_no_inmo,
  COALESCE(co.cal_mm_dup, 0) cal_mm_dup,
  COALESCE(co.cal_mm_desc, 0) cal_mm_desc,
  COALESCE(co.incomp, 0) incomp,
  COALESCE(co.dup, 0) dup,
  COALESCE(ev.e_cal_mm, 0) e_cal_mm,
  COALESCE(ev.e_cal_inmo, 0) e_cal_inmo,
  COALESCE(ev.e_cal_mm_no_inmo, 0) e_cal_mm_no_inmo
FROM cohort_all co
FULL OUTER JOIN events_all ev USING (g, c, f, p)
ORDER BY g, c, f, p
