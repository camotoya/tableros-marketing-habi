-- Antifunnel Sellers (CO + MX)
-- Por cada combinación de país, fuente, temporalidad y estado actual (last_estado_id)
-- cuenta los leads NO calificados (estado ≠ 20, 63) agrupados por fecha_creacion.
-- Output: g, c, f, p, state_id, state_name, n
-- Respeta los mismos filtros de fuente y ventanas que query.sql.

WITH base AS (
  SELECT 'Colombia' AS c, tig.fuente_id,
    DATE(tig.fecha_creacion) AS fecha,
    tni.last_estado_id AS state_id
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` tig
  LEFT JOIN `sellers-main-prod.co_rds_staging.habi_db_tabla_negocio_inmueble` tni ON tni.id = tig.negocio_id
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 20, 35, 39, 47)
    AND tni.last_estado_id IS NOT NULL
    AND tni.last_estado_id NOT IN (20, 63)

  UNION ALL

  SELECT 'México' AS c, tig.fuente_id,
    DATE(tig.fecha_creacion) AS fecha,
    tni.last_state_id AS state_id
  FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` tig
  LEFT JOIN `sellers-main-prod.mx_rds_staging.habi_db_property_deal` tni ON tni.id = tig.id_negocio
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.fuente_id IN (3, 7, 35, 39, 46, 47)
    AND tni.last_state_id IS NOT NULL
    AND tni.last_state_id NOT IN (20, 63)
),

catalog AS (
  SELECT id, estado FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_estados`
),

day_periods AS (SELECT DISTINCT fecha FROM base ORDER BY fecha DESC LIMIT 25),
week_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, ISOWEEK) p FROM base ORDER BY p DESC LIMIT 25),
comm_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, WEEK(WEDNESDAY)) p FROM base ORDER BY p DESC LIMIT 25),
month_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, MONTH) p FROM base ORDER BY p DESC LIMIT 25),
quarter_periods AS (SELECT DISTINCT DATE_TRUNC(fecha, QUARTER) p FROM base ORDER BY p DESC LIMIT 25),

daily AS (
  SELECT 'D' g, c, fuente_id f, CAST(fecha AS STRING) p, state_id, COUNT(*) n
  FROM base WHERE fecha IN (SELECT fecha FROM day_periods) GROUP BY c, f, p, state_id
),
weekly AS (
  SELECT 'W' g, c, fuente_id f, CAST(DATE_TRUNC(fecha, ISOWEEK) AS STRING) p, state_id, COUNT(*) n
  FROM base WHERE DATE_TRUNC(fecha, ISOWEEK) IN (SELECT p FROM week_periods) GROUP BY c, f, p, state_id
),
commercial AS (
  SELECT 'C' g, c, fuente_id f, CAST(DATE_TRUNC(fecha, WEEK(WEDNESDAY)) AS STRING) p, state_id, COUNT(*) n
  FROM base WHERE DATE_TRUNC(fecha, WEEK(WEDNESDAY)) IN (SELECT p FROM comm_periods) GROUP BY c, f, p, state_id
),
monthly AS (
  SELECT 'M' g, c, fuente_id f, FORMAT_DATE('%Y-%m', fecha) p, state_id, COUNT(*) n
  FROM base WHERE DATE_TRUNC(fecha, MONTH) IN (SELECT p FROM month_periods) GROUP BY c, f, p, state_id
),
quarterly AS (
  SELECT 'Q' g, c, fuente_id f,
    CONCAT(CAST(EXTRACT(YEAR FROM fecha) AS STRING), '-Q', CAST(EXTRACT(QUARTER FROM fecha) AS STRING)) p,
    state_id, COUNT(*) n
  FROM base WHERE DATE_TRUNC(fecha, QUARTER) IN (SELECT p FROM quarter_periods) GROUP BY c, f, p, state_id
),
yearly AS (
  SELECT 'Y' g, c, fuente_id f, CAST(EXTRACT(YEAR FROM fecha) AS STRING) p, state_id, COUNT(*) n
  FROM base GROUP BY c, f, p, state_id
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
  a.state_id,
  COALESCE(cat.estado, CONCAT('state_', CAST(a.state_id AS STRING))) AS state_name,
  a.n
FROM all_rows a
LEFT JOIN catalog cat ON cat.id = a.state_id
ORDER BY a.g, a.c, a.f, a.p, a.n DESC
