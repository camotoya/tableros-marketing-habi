-- Distribución por estado Inmo de los leads que calificaron MM pero nunca calificaron Inmo.
-- Clave para entender la violación MM⊆Inmo: dónde se atascan los leads que "no debería" haber.
-- Output: g, c, f, p, state_id, state_name, n
-- Denominador sugerido en frontend: cal_mm del período.

WITH base AS (
  SELECT 'Colombia' AS c, tig.fuente_id,
    DATE(tig.fecha_creacion) AS fecha,
    tig.negocio_id AS biz_id,
    tni.last_state_id_real_estate AS inmo_state
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` tig
  LEFT JOIN `sellers-main-prod.co_rds_staging.habi_db_tabla_negocio_inmueble` tni ON tni.id = tig.negocio_id
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 20, 35, 39, 47)

  UNION ALL

  SELECT 'México' AS c, tig.fuente_id,
    DATE(tig.fecha_creacion) AS fecha,
    tig.id_negocio AS biz_id,
    tni.last_state_id_real_estate AS inmo_state
  FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` tig
  LEFT JOIN `sellers-main-prod.mx_rds_staging.habi_db_property_deal` tni ON tni.id = tig.id_negocio
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 35, 39, 46, 47)
),

cal_mm AS (
  SELECT 'Colombia' AS c, negocio_id AS biz_id
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
  WHERE estado_id IN (20, 63) AND negocio_id IS NOT NULL
  GROUP BY c, biz_id
  UNION ALL
  SELECT 'México' AS c, deal_id AS biz_id
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state`
  WHERE state_id IN (20, 63) AND deal_id IS NOT NULL
  GROUP BY c, biz_id
),

cal_inmo AS (
  SELECT 'Colombia' AS c, deal_id AS biz_id
  FROM `sellers-main-prod.co_rds_staging.habi_db_history_state_real_estate`
  WHERE state_id = 20 AND deal_id IS NOT NULL
  GROUP BY c, biz_id
  UNION ALL
  SELECT 'México' AS c, deal_id AS biz_id
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state_real_estate`
  WHERE state_id = 20 AND deal_id IS NOT NULL
  GROUP BY c, biz_id
),

candidates AS (
  SELECT b.c, b.fuente_id, b.fecha, b.inmo_state
  FROM base b
  JOIN cal_mm m ON m.c = b.c AND m.biz_id = b.biz_id
  LEFT JOIN cal_inmo i ON i.c = b.c AND i.biz_id = b.biz_id
  WHERE i.biz_id IS NULL
),

catalog AS (
  SELECT id, estado FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_estados`
),

day_periods AS (SELECT DISTINCT fecha FROM candidates ORDER BY fecha DESC LIMIT 25),
week_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, ISOWEEK) p FROM candidates ORDER BY p DESC LIMIT 25),
comm_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, WEEK(WEDNESDAY)) p FROM candidates ORDER BY p DESC LIMIT 25),
month_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, MONTH) p FROM candidates ORDER BY p DESC LIMIT 25),
quarter_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, QUARTER) p FROM candidates ORDER BY p DESC LIMIT 25),

daily AS (
  SELECT 'D' g, c, fuente_id f, CAST(fecha AS STRING) p, inmo_state state_id, COUNT(*) n
  FROM candidates WHERE fecha IN (SELECT fecha FROM day_periods) GROUP BY c, f, p, state_id
),
weekly AS (
  SELECT 'W' g, c, fuente_id f, CAST(DATE_TRUNC(fecha, ISOWEEK) AS STRING) p, inmo_state state_id, COUNT(*) n
  FROM candidates WHERE DATE_TRUNC(fecha, ISOWEEK) IN (SELECT p FROM week_periods) GROUP BY c, f, p, state_id
),
commercial AS (
  SELECT 'C' g, c, fuente_id f, CAST(DATE_TRUNC(fecha, WEEK(WEDNESDAY)) AS STRING) p, inmo_state state_id, COUNT(*) n
  FROM candidates WHERE DATE_TRUNC(fecha, WEEK(WEDNESDAY)) IN (SELECT p FROM comm_periods) GROUP BY c, f, p, state_id
),
monthly AS (
  SELECT 'M' g, c, fuente_id f, FORMAT_DATE('%Y-%m', fecha) p, inmo_state state_id, COUNT(*) n
  FROM candidates WHERE DATE_TRUNC(fecha, MONTH) IN (SELECT p FROM month_periods) GROUP BY c, f, p, state_id
),
quarterly AS (
  SELECT 'Q' g, c, fuente_id f,
    CONCAT(CAST(EXTRACT(YEAR FROM fecha) AS STRING), '-Q', CAST(EXTRACT(QUARTER FROM fecha) AS STRING)) p,
    inmo_state state_id, COUNT(*) n
  FROM candidates WHERE DATE_TRUNC(fecha, QUARTER) IN (SELECT p FROM quarter_periods) GROUP BY c, f, p, state_id
),
yearly AS (
  SELECT 'Y' g, c, fuente_id f, CAST(EXTRACT(YEAR FROM fecha) AS STRING) p, inmo_state state_id, COUNT(*) n
  FROM candidates GROUP BY c, f, p, state_id
),

all_rows AS (
  SELECT * FROM daily
  UNION ALL SELECT * FROM weekly
  UNION ALL SELECT * FROM commercial
  UNION ALL SELECT * FROM monthly
  UNION ALL SELECT * FROM quarterly
  UNION ALL SELECT * FROM yearly
)

SELECT
  a.g, a.c, a.f, a.p,
  COALESCE(a.state_id, -1) AS state_id,
  COALESCE(cat.estado, IF(a.state_id IS NULL, '(sin registro Inmo)', CONCAT('state_', CAST(a.state_id AS STRING)))) AS state_name,
  a.n
FROM all_rows a
LEFT JOIN catalog cat ON cat.id = a.state_id
ORDER BY a.g, a.c, a.f, a.p, a.n DESC
