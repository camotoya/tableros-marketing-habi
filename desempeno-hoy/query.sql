-- Tablero desempeno-hoy: calificados MM hora por hora (CO/MX).
-- Placeholders reemplazados por el workflow via sed:
--   __TIG__         papyrus-data.habi_wh_bi.tabla_inmuebles_general (CO)
--                   papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general (MX)
--   __TIG_ID__      negocio_id (CO)  | id_negocio (MX)
--   __HIST__        sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2 (CO)
--                   sellers-main-prod.mx_rds_staging.habi_db_history_state (MX)
--   __HIST_ID__     negocio_id (CO)  | deal_id (MX)
--   __STATE_COL__   estado_id (CO)   | state_id (MX)
--   __FECHA_COL__   fecha_actualizacion (CO) | date_create (MX)
--   __TZ_OFFSET__   -5 (CO) | -6 (MX, sin DST)
-- Ventanas: primer_calif 40d (today + prev_week + 4 weekday previos + buffer).
--           lead_fuente 60d (cubre leads creados antes que califican hoy).
WITH lead_fuente AS (
  SELECT
    __TIG_ID__ AS deal_id,
    CASE fuente_id
      WHEN 3  THEN 'WEB'
      WHEN 7  THEN 'Habimetro'
      WHEN 20 THEN 'CRM'
      WHEN 35 THEN 'Comercial'
      WHEN 39 THEN 'Broker'
      WHEN 46 THEN 'Propiedades'
      WHEN 47 THEN 'Leadforms'
    END AS fuente_label
  FROM `__TIG__`
  WHERE fecha_creacion >= DATETIME_SUB(CURRENT_DATETIME(), INTERVAL 60 DAY)
    AND __TIG_ID__ IS NOT NULL
    AND fuente_id IN (3, 7, 20, 35, 39, 46, 47)
),
primer_calif AS (
  SELECT
    __HIST_ID__ AS deal_id,
    MIN(__FECHA_COL__) AS ts_calif_utc
  FROM `__HIST__`
  WHERE __STATE_COL__ IN (20, 63)
    AND __FECHA_COL__ >= DATETIME_SUB(CURRENT_DATETIME(), INTERVAL 40 DAY)
  GROUP BY 1
)
SELECT
  DATE(DATETIME_ADD(p.ts_calif_utc, INTERVAL __TZ_OFFSET__ HOUR)) AS fecha_local,
  EXTRACT(HOUR FROM DATETIME_ADD(p.ts_calif_utc, INTERVAL __TZ_OFFSET__ HOUR)) + 1 AS hora_1_24,
  f.fuente_label,
  COUNT(DISTINCT p.deal_id) AS calificados
FROM primer_calif p
JOIN lead_fuente f USING (deal_id)
WHERE f.fuente_label IS NOT NULL
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
