-- Asignados — Explorador de Filtros (CO) — TIG-only
-- Universe: leads con primera asignación registrada en TIG. F1+F2 implicit via fecha_primer_asignacion.
-- Window: últimos 540 días (~18 meses).
-- F16 (UTC-5) no aplica: TIG dates ya están en hora Colombia.
-- F6 y F15 marcados como bloqueados (no accesibles desde las tablas que tenemos).
--   - F6 requiere contacto_digital (solo existe en papyrus-staging.src_sellers_hubspot.deal)
--   - F15 requiere asignacion_descartes_top (no existe en tabla_inmuebles_general)
--   Ambos hardcoded a "siempre pasa" en el bitmask para que no afecten el conteo.
-- 13 bits: F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15

WITH
asignaciones_base AS (
  SELECT
    CAST(nid AS STRING) AS nid,
    DATE(fecha_primer_asignacion) AS fecha_asignacion,
    fuente_id,
    hubspot_owner_id,
    LOWER(TRIM(estado)) AS estado_lower,
    LOWER(TRIM(calificacion_del_lead_v2)) AS calificacion_lower,
    check_a_pricing,
    fecha_creacion
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general`
  WHERE fecha_primer_asignacion IS NOT NULL
    AND DATE(fecha_primer_asignacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
),

con_email AS (
  SELECT
    a.*,
    LOWER(IFNULL(sc.email, a.hubspot_owner_id)) AS owner_email_lower
  FROM asignaciones_base a
  LEFT JOIN `papyrus-data.habi_wh_bi.sc_users_hubspot` sc
    ON a.hubspot_owner_id = CAST(sc.id_segundario AS STRING)
),

calificados AS (
  SELECT DISTINCT CAST(negocio_id AS STRING) AS nid
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
  WHERE estado_id IN (20, 63)
),

con_flags AS (
  SELECT
    a.fecha_asignacion,
    IF(c.nid IS NOT NULL, 1, 0) AS calificado,
    CASE
      WHEN a.fuente_id = 7 THEN 'Habimetro'
      WHEN a.fuente_id = 20 THEN 'CRM'
      WHEN a.fuente_id = 39 THEN 'Broker'
      WHEN a.fuente_id = 3 THEN 'WEB'
      WHEN a.fuente_id = 1 THEN 'Ventanas'
      WHEN a.fuente_id IN (47, 37, 41, 42) THEN 'Leadform'
      ELSE 'Otro'
    END AS fuente_label,
    (
      -- bit 0: F3 correo contiene "habi."
      IF(a.owner_email_lower LIKE '%habi.%', 1, 0)
      -- bit 1: F4 no contiene agente/delta/call
      + IF(a.owner_email_lower NOT LIKE '%agente%'
           AND a.owner_email_lower NOT LIKE '%delta%'
           AND a.owner_email_lower NOT LIKE '%call%', 2, 0)
      -- bit 2: F5 no en hardcoded list
      + IF(a.owner_email_lower NOT IN (
             'alejandroaguirre@habi.co',
             'erickcastillo@tuhabi.mx',
             'victorialechtig@tuhabi.mx'), 4, 0)
      -- bit 3: F6 BLOQUEADO (contacto_digital no accesible) — hardcoded 1
      + 8
      -- bit 4: F7 estado=sin pricing incial
      + IF(a.estado_lower = 'sin pricing incial', 16, 0)
      -- bit 5: F8 estado=no gestionado
      + IF(a.estado_lower = 'no gestionado', 32, 0)
      -- bit 6: F9 estado=cierre
      + IF(a.estado_lower = 'cierre', 64, 0)
      -- bit 7: F10 estado=no hay suficientes datos
      + IF(a.estado_lower = 'no hay suficientes datos para comparar', 128, 0)
      -- bit 8: F11 calificación NOT IN (n, nh)
      + IF(IFNULL(a.calificacion_lower, '') NOT IN ('n', 'nh'), 256, 0)
      -- bit 9: F12 check_a_pricing = 1
      + IF(a.check_a_pricing = 1, 512, 0)
      -- bit 10: F13 fecha_creacion no nula
      + IF(a.fecha_creacion IS NOT NULL, 1024, 0)
      -- bit 11: F14 nid no nulo (siempre 1 por filtro de la CTE base)
      + 2048
      -- bit 12: F15 BLOQUEADO (asignacion_descartes_top no en TIG) — hardcoded 1
      + 4096
    ) AS bitmask
  FROM con_email a
  LEFT JOIN calificados c ON a.nid = c.nid
)

SELECT
  fecha_asignacion AS d,
  bitmask AS m,
  calificado AS c,
  fuente_label AS f,
  COUNT(*) AS n
FROM con_flags
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 2, 3, 4
