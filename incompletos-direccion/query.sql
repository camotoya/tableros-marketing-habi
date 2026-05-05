-- Funnel Incompletos / Revisar Dirección — CO + MX
-- Cohort por fecha_creacion. Para cada lead determinamos:
--   ever_inc   = pasó alguna vez por estado 7 (incompleto) o 39 (incompleto desde web). Se agrupan.
--   ever_rev   = pasó alguna vez por estado 3 (revisar dirección).
--   inc_to_20  = pasó por incompleto Y luego entró al estado 20 (calificado) en una transición posterior.
--   rev_to_20  = pasó por revisar dirección Y luego entró al estado 20.
--   cur_state  = estado actual (last_estado_id en CO, last_state_id en MX) en OLTP.
-- Salida por (g, c, f, p):
--   tr, t, inc_pass, inc_left, inc_to_20, rev_pass, rev_left, rev_to_20.
--
-- IDs de estado verificados en catálogos co_rds_staging.habi_db_tabla_estados y mx_rds_staging.habi_db_state.

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

-- Single pass sobre la histórica por país.
-- ever_*  : marca si el lead alguna vez pasó por el grupo de estados.
-- first_* : DATETIME de la PRIMERA entrada al estado fuente (7+39 / 3).
-- last_20 : DATETIME de la ÚLTIMA entrada al estado 20.
-- inc_to_20 / rev_to_20 = ever_* AND last_20 > first_*  (entró a 20 DESPUÉS de pasar por el estado fuente).
historic AS (
  SELECT 'Colombia' AS c, negocio_id AS biz_id,
    MAX(IF(estado_id IN (7, 39), 1, 0)) AS ever_inc,
    MAX(IF(estado_id = 3, 1, 0)) AS ever_rev,
    MIN(CASE WHEN estado_id IN (7, 39) THEN DATETIME(fecha_actualizacion) END) AS first_inc,
    MIN(CASE WHEN estado_id = 3        THEN DATETIME(fecha_actualizacion) END) AS first_rev,
    MAX(CASE WHEN estado_id = 20       THEN DATETIME(fecha_actualizacion) END) AS last_20
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
  WHERE negocio_id IS NOT NULL AND estado_id IN (3, 7, 20, 39)
  GROUP BY c, biz_id

  UNION ALL

  SELECT 'México' AS c, deal_id AS biz_id,
    MAX(IF(state_id IN (7, 39), 1, 0)) AS ever_inc,
    MAX(IF(state_id = 3, 1, 0)) AS ever_rev,
    MIN(CASE WHEN state_id IN (7, 39) THEN DATETIME(date_create) END) AS first_inc,
    MIN(CASE WHEN state_id = 3        THEN DATETIME(date_create) END) AS first_rev,
    MAX(CASE WHEN state_id = 20       THEN DATETIME(date_create) END) AS last_20
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state`
  WHERE deal_id IS NOT NULL AND state_id IN (3, 7, 20, 39)
  GROUP BY c, biz_id
),

current_state AS (
  SELECT 'Colombia' AS c, id AS biz_id, last_estado_id AS st
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_negocio_inmueble`
  UNION ALL
  SELECT 'México' AS c, id AS biz_id, last_state_id AS st
  FROM `sellers-main-prod.mx_rds_staging.habi_db_property_deal`
),

enriched AS (
  SELECT b.c, b.nid, b.fuente_id, b.fuente, b.fecha,
    cs.st AS cur_state,
    COALESCE(h.ever_inc, 0) AS ever_inc,
    COALESCE(h.ever_rev, 0) AS ever_rev,
    IF(h.ever_inc = 1 AND h.last_20 IS NOT NULL AND h.first_inc IS NOT NULL AND h.last_20 > h.first_inc, 1, 0) AS inc_to_20,
    IF(h.ever_rev = 1 AND h.last_20 IS NOT NULL AND h.first_rev IS NOT NULL AND h.last_20 > h.first_rev, 1, 0) AS rev_to_20
  FROM base b
  LEFT JOIN historic h ON h.c = b.c AND h.biz_id = b.biz_id
  LEFT JOIN current_state cs ON cs.c = b.c AND cs.biz_id = b.biz_id
),

day_periods AS (SELECT DISTINCT fecha FROM enriched ORDER BY fecha DESC LIMIT 25),
week_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, ISOWEEK) p FROM enriched ORDER BY p DESC LIMIT 25),
comm_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, WEEK(WEDNESDAY)) p FROM enriched ORDER BY p DESC LIMIT 25),
month_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, MONTH) p FROM enriched ORDER BY p DESC LIMIT 25),
quarter_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, QUARTER) p FROM enriched ORDER BY p DESC LIMIT 25),

agg_daily AS (
  SELECT 'D' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(fecha AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(ever_inc = 1) inc_pass,
    COUNTIF(ever_inc = 1 AND (cur_state IS NULL OR cur_state NOT IN (7, 39))) inc_left,
    COUNTIF(inc_to_20 = 1) inc_to_20,
    COUNTIF(ever_rev = 1) rev_pass,
    COUNTIF(ever_rev = 1 AND (cur_state IS NULL OR cur_state != 3)) rev_left,
    COUNTIF(rev_to_20 = 1) rev_to_20
  FROM enriched WHERE fecha IN (SELECT fecha FROM day_periods) GROUP BY c, f, p
),
agg_weekly AS (
  SELECT 'W' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(fecha, ISOWEEK) AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(ever_inc = 1) inc_pass,
    COUNTIF(ever_inc = 1 AND (cur_state IS NULL OR cur_state NOT IN (7, 39))) inc_left,
    COUNTIF(inc_to_20 = 1) inc_to_20,
    COUNTIF(ever_rev = 1) rev_pass,
    COUNTIF(ever_rev = 1 AND (cur_state IS NULL OR cur_state != 3)) rev_left,
    COUNTIF(rev_to_20 = 1) rev_to_20
  FROM enriched WHERE DATE_TRUNC(fecha, ISOWEEK) IN (SELECT p FROM week_periods) GROUP BY c, f, p
),
agg_commercial AS (
  SELECT 'C' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(DATE_TRUNC(fecha, WEEK(WEDNESDAY)) AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(ever_inc = 1) inc_pass,
    COUNTIF(ever_inc = 1 AND (cur_state IS NULL OR cur_state NOT IN (7, 39))) inc_left,
    COUNTIF(inc_to_20 = 1) inc_to_20,
    COUNTIF(ever_rev = 1) rev_pass,
    COUNTIF(ever_rev = 1 AND (cur_state IS NULL OR cur_state != 3)) rev_left,
    COUNTIF(rev_to_20 = 1) rev_to_20
  FROM enriched WHERE DATE_TRUNC(fecha, WEEK(WEDNESDAY)) IN (SELECT p FROM comm_periods) GROUP BY c, f, p
),
agg_monthly AS (
  SELECT 'M' g, c, fuente_id f, ANY_VALUE(fuente) fn, FORMAT_DATE('%Y-%m', fecha) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(ever_inc = 1) inc_pass,
    COUNTIF(ever_inc = 1 AND (cur_state IS NULL OR cur_state NOT IN (7, 39))) inc_left,
    COUNTIF(inc_to_20 = 1) inc_to_20,
    COUNTIF(ever_rev = 1) rev_pass,
    COUNTIF(ever_rev = 1 AND (cur_state IS NULL OR cur_state != 3)) rev_left,
    COUNTIF(rev_to_20 = 1) rev_to_20
  FROM enriched WHERE DATE_TRUNC(fecha, MONTH) IN (SELECT p FROM month_periods) GROUP BY c, f, p
),
agg_quarterly AS (
  SELECT 'Q' g, c, fuente_id f, ANY_VALUE(fuente) fn,
    CONCAT(CAST(EXTRACT(YEAR FROM fecha) AS STRING), '-Q', CAST(EXTRACT(QUARTER FROM fecha) AS STRING)) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(ever_inc = 1) inc_pass,
    COUNTIF(ever_inc = 1 AND (cur_state IS NULL OR cur_state NOT IN (7, 39))) inc_left,
    COUNTIF(inc_to_20 = 1) inc_to_20,
    COUNTIF(ever_rev = 1) rev_pass,
    COUNTIF(ever_rev = 1 AND (cur_state IS NULL OR cur_state != 3)) rev_left,
    COUNTIF(rev_to_20 = 1) rev_to_20
  FROM enriched WHERE DATE_TRUNC(fecha, QUARTER) IN (SELECT p FROM quarter_periods) GROUP BY c, f, p
),
agg_yearly AS (
  SELECT 'Y' g, c, fuente_id f, ANY_VALUE(fuente) fn, CAST(EXTRACT(YEAR FROM fecha) AS STRING) p,
    COUNT(*) tr, COUNT(DISTINCT nid) t,
    COUNTIF(ever_inc = 1) inc_pass,
    COUNTIF(ever_inc = 1 AND (cur_state IS NULL OR cur_state NOT IN (7, 39))) inc_left,
    COUNTIF(inc_to_20 = 1) inc_to_20,
    COUNTIF(ever_rev = 1) rev_pass,
    COUNTIF(ever_rev = 1 AND (cur_state IS NULL OR cur_state != 3)) rev_left,
    COUNTIF(rev_to_20 = 1) rev_to_20
  FROM enriched GROUP BY c, f, p
)

SELECT g, c, f, fn, p, tr, t, inc_pass, inc_left, inc_to_20, rev_pass, rev_left, rev_to_20 FROM (
  SELECT * FROM agg_daily
  UNION ALL SELECT * FROM agg_weekly
  UNION ALL SELECT * FROM agg_commercial
  UNION ALL SELECT * FROM agg_monthly
  UNION ALL SELECT * FROM agg_quarterly
  UNION ALL SELECT * FROM agg_yearly
)
ORDER BY g, c, f, p
