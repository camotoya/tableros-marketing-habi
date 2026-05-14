-- Asignados por fecha de creación del lead (CO)
-- Output: tres series con UNION ALL:
--   series='mart' → row por (d, f) con count del WBR mart
--   series='ever' → row por (d, f, m) con count del universo ever-asignado, m es bitmask
--   series='gap'  → row por (d, f, bucket) con count de leads ever-asignado NO en mart,
--                   atribuidos por prioridad al primer filtro que fallan
-- Window: últimos 540 días. Sólo 6 fuentes de marketing.
-- Bitmask (5 bits) sobre ever-asignado:
--   bit 0 = F7-F10 estado, bit 1 = F12, bit 2 = F15 proxy, bit 3 = F3, bit 4 = F11
-- Atribución prioritaria del gap (orden descendente por drop total):
--   F7-F10 > F12 > F15 > F3 > F11 > Otro

WITH tig AS (
  SELECT
    CAST(t.nid AS STRING)                    AS nid,
    DATE(t.fecha_creacion)                   AS d,
    CASE
      WHEN t.fuente_id = 3                       THEN 'WEB'
      WHEN t.fuente_id IN (47, 37, 41, 42)       THEN 'Leadforms'
      WHEN t.fuente_id = 7                       THEN 'Habimetro'
      WHEN t.fuente_id = 20                      THEN 'CRM'
      WHEN t.fuente_id = 39                      THEN 'Brokers'
      WHEN t.fuente_id = 35                      THEN 'Comercial'
    END                                          AS f,
    LOWER(IFNULL(sc.email, t.hubspot_owner_id))  AS owner_email_lower,
    REPLACE(LOWER(TRIM(IFNULL(t.estado, ''))), '_', ' ') AS estado_norm,
    LOWER(TRIM(IFNULL(t.calificacion_del_lead_v2, ''))) AS calificacion_lower,
    t.check_a_pricing,
    t.inmobiliaria,
    (t.fecha_primer_asignacion IS NOT NULL OR t.hubspot_owner_id IS NOT NULL) AS ever_owner
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` t
  LEFT JOIN `papyrus-data.habi_wh_bi.sc_users_hubspot` sc
    ON t.hubspot_owner_id = CAST(sc.id_segundario AS STRING)
  WHERE t.fecha_creacion IS NOT NULL
    AND DATE(t.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
),

tig_flagged AS (
  SELECT
    nid, d, f, ever_owner,
    IF(estado_norm IN (
      'sin pricing incial', 'sin pricing inicial',
      'no gestionado', 'cierre',
      'no hay suficientes datos para comparar'
    ), 1, 0) AS pf_estado,
    IF(check_a_pricing = 1, 1, 0) AS pf_f12,
    IF(inmobiliaria IS NULL OR inmobiliaria = 0, 1, 0) AS pf_f15,
    IF(owner_email_lower LIKE '%habi.%', 1, 0) AS pf_f3,
    IF(calificacion_lower NOT IN ('n', 'nh'), 1, 0) AS pf_f11
  FROM tig
  WHERE f IS NOT NULL
),

mart_nids AS (
  SELECT DISTINCT CAST(nid AS STRING) AS nid
  FROM `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart`
  WHERE pais = 'colombia'
),

mart_rows AS (
  SELECT
    DATE(t.fecha_creacion) AS d,
    CASE
      WHEN t.fuente_id = 3                       THEN 'WEB'
      WHEN t.fuente_id IN (47, 37, 41, 42)       THEN 'Leadforms'
      WHEN t.fuente_id = 7                       THEN 'Habimetro'
      WHEN t.fuente_id = 20                      THEN 'CRM'
      WHEN t.fuente_id = 39                      THEN 'Brokers'
      WHEN t.fuente_id = 35                      THEN 'Comercial'
    END AS f,
    CAST(NULL AS INT64) AS m,
    CAST(NULL AS STRING) AS bucket,
    'mart' AS series,
    COUNT(*) AS n
  FROM `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart` mart
  INNER JOIN `papyrus-data.habi_wh_bi.tabla_inmuebles_general` t
    ON mart.nid = t.nid
  WHERE mart.pais = 'colombia'
    AND t.fecha_creacion IS NOT NULL
    AND DATE(t.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
  GROUP BY 1, 2
  HAVING f IS NOT NULL
),

ever_rows AS (
  SELECT
    d, f,
    (pf_estado * 1 + pf_f12 * 2 + pf_f15 * 4 + pf_f3 * 8 + pf_f11 * 16) AS m,
    CAST(NULL AS STRING) AS bucket,
    'ever' AS series,
    COUNT(*) AS n
  FROM tig_flagged
  WHERE ever_owner
  GROUP BY 1, 2, 3
),

gap_pre AS (
  SELECT
    t.d,
    t.f,
    CASE
      WHEN t.pf_estado = 0 THEN 'F7-F10'
      WHEN t.pf_f12 = 0    THEN 'F12'
      WHEN t.pf_f15 = 0    THEN 'F15'
      WHEN t.pf_f3 = 0     THEN 'F3'
      WHEN t.pf_f11 = 0    THEN 'F11'
      ELSE 'Otro'
    END AS bucket
  FROM tig_flagged t
  LEFT JOIN mart_nids m ON t.nid = m.nid
  WHERE t.ever_owner
    AND m.nid IS NULL  -- ever-asignado pero NO en mart
),

gap_rows AS (
  SELECT
    d, f,
    CAST(NULL AS INT64) AS m,
    bucket,
    'gap' AS series,
    COUNT(*) AS n
  FROM gap_pre
  GROUP BY d, f, bucket
)

SELECT * FROM mart_rows
UNION ALL
SELECT * FROM ever_rows
UNION ALL
SELECT * FROM gap_rows
ORDER BY series, d, f
