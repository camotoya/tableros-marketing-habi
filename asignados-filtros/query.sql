-- Asignados — Explorador de Filtros (CO)
-- Output: one row per (fecha_asignacion, bitmask, calificado, fuente_label) with COUNT.
-- Window: last 540 days (covers 18 months for monthly granularity).
-- F1+F2+F16 applied as structural filters (universe base).
-- 13 toggleable flags packed into a bitmask (bit 0 = F3, ..., bit 12 = F15).

WITH
-- F1 + F2: first hubspot_owner_id change per nid, F16 applied (UTC-5).
-- Window: last 540 days (~18 months). fecha_inicio computed inline.
asignaciones_base AS (
  SELECT
    nid,
    DATETIME_SUB(fecha, INTERVAL 5 HOUR) AS fecha_asignacion_co,
    valor AS owner_id_raw
  FROM `papyrus-master.src_sellers_hubspot.history`
  WHERE propiedad = 'hubspot_owner_id'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY nid ORDER BY fecha ASC) = 1
),

asignaciones_ventana AS (
  SELECT *
  FROM asignaciones_base
  WHERE DATE(fecha_asignacion_co) >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
),

asignaciones_con_email AS (
  SELECT
    a.nid,
    a.fecha_asignacion_co,
    LOWER(IFNULL(sc.email, a.owner_id_raw)) AS owner_email_lower
  FROM asignaciones_ventana a
  LEFT JOIN `papyrus-data.habi_wh_bi.sc_users_hubspot` sc
    ON a.owner_id_raw = CAST(sc.id_segundario AS STRING)
),

calificados AS (
  SELECT DISTINCT CAST(negocio_id AS STRING) AS nid
  FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
  WHERE estado_id IN (20, 63)
),

deal_info AS (
  SELECT
    CAST(nid AS STRING) AS nid,
    LOWER(TRIM(estado)) AS estado_lower,
    contacto_digital
  FROM `papyrus-staging.src_sellers_hubspot.deal`
),

inmueble_info AS (
  SELECT
    CAST(nid AS STRING) AS nid,
    fuente_id,
    LOWER(TRIM(calificacion_del_lead_v2)) AS calificacion_lower,
    check_a_pricing,
    fecha_creacion
    -- F15 (asignacion_descartes_top) intencionalmente omitido: la columna no existe
    -- en `tabla_inmuebles_general` con los accesos disponibles. El bit 12 se
    -- establece siempre a 1 (toggle dummy) y se documenta en el tooltip.
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general`
),

con_flags AS (
  SELECT
    DATE(a.fecha_asignacion_co) AS fecha_asignacion,
    IF(c.nid IS NOT NULL, 1, 0) AS calificado,
    CASE
      WHEN i.fuente_id = 7 THEN 'Habimetro'
      WHEN i.fuente_id = 20 THEN 'CRM'
      WHEN i.fuente_id = 39 THEN 'Broker'
      WHEN i.fuente_id = 3 THEN 'WEB'
      WHEN i.fuente_id = 1 THEN 'Ventanas'
      WHEN i.fuente_id IN (47, 37, 41, 42) THEN 'Leadform'
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
      -- bit 3: F6 special owners require contacto_digital
      + IF(a.owner_email_lower NOT IN (
             'lauracruz@habi.co','alejandrobravo@habi.co',
             'juanquinones@habi.co','juanarcos@habi.co')
           OR d.contacto_digital IS NOT NULL, 8, 0)
      -- bit 4: F7 estado=sin pricing incial
      + IF(d.estado_lower = 'sin pricing incial', 16, 0)
      -- bit 5: F8 estado=no gestionado
      + IF(d.estado_lower = 'no gestionado', 32, 0)
      -- bit 6: F9 estado=cierre
      + IF(d.estado_lower = 'cierre', 64, 0)
      -- bit 7: F10 estado=no hay suficientes datos para comparar
      + IF(d.estado_lower = 'no hay suficientes datos para comparar', 128, 0)
      -- bit 8: F11 calificación NOT IN (n, nh)
      + IF(IFNULL(i.calificacion_lower, '') NOT IN ('n', 'nh'), 256, 0)
      -- bit 9: F12 check_a_pricing = 1
      + IF(i.check_a_pricing = 1, 512, 0)
      -- bit 10: F13 fecha_creacion no nula
      + IF(i.fecha_creacion IS NOT NULL, 1024, 0)
      -- bit 11: F14 nid no nulo
      + IF(i.nid IS NOT NULL, 2048, 0)
      -- bit 12: F15 (dummy en v1 — columna asignacion_descartes_top no accesible)
      + 4096
    ) AS bitmask
  FROM asignaciones_con_email a
  LEFT JOIN deal_info d ON a.nid = d.nid
  LEFT JOIN inmueble_info i ON a.nid = i.nid
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
