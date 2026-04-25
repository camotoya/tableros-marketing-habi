-- Funnel Sellers (CO + MX) — Cohort por fecha de creación
-- Campos por fila: g, c, f, fn, p, tr, t, cal_mm, cal_inmo, cal_mm_no_inmo, cal_mm_dup, cal_mm_desc, incomp, dup
--   tr             = Registros totales (COUNT(*), por fecha_creacion)
--   t              = Registros con NID (COUNT DISTINCT nid, por fecha_creacion)
--   cal_mm         = leads creados en el período que alguna vez fueron calificados MM
--   cal_inmo       = leads creados en el período que alguna vez fueron calificados Inmo
--   cal_mm_no_inmo = calificaron MM pero nunca Inmo (violación MM⊆Inmo)
--   cal_mm_dup     = calificaron MM y su estado actual es duplicado (1)
--   cal_mm_desc    = calificaron MM y su estado actual es descarte tardío (3,10,16,33,38,55,56,61,64)
--   incomp         = estado actual = 7 (incompleto)
--   dup            = estado actual = 1 (duplicado)
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
)

SELECT g, c, f, fn, p, tr, t, cal_mm, cal_inmo, cal_mm_no_inmo, cal_mm_dup, cal_mm_desc, incomp, dup
FROM (
  SELECT * FROM cohort_daily UNION ALL SELECT * FROM cohort_weekly UNION ALL SELECT * FROM cohort_commercial
  UNION ALL SELECT * FROM cohort_monthly UNION ALL SELECT * FROM cohort_quarterly UNION ALL SELECT * FROM cohort_yearly
)
ORDER BY g, c, f, p
