-- Asignados por fecha de creación del lead (CO + MX)
-- Output: 5 series con UNION ALL, cada row con un campo `pais` ('CO' | 'MX'):
--   series='mart'         → (pais, d, f, n) → count del WBR mart
--   series='ever'         → (pais, d, f, m, n) → universo ever-asignado, m es bitmask
--   series='gap'          → (pais, d, f, bucket, n) → leads ever-asignado NO en mart
--   series='leads_attr'   → (pais, d, f, canal, plataforma, n) → registros con UTM populated
--   series='spend'        → (pais, d, f, canal, plataforma, spend, clicks, impressions)
-- Window: últimos 540 días.
-- Bitmask (5 bits) sobre ever-asignado:
--   bit 0 = F7-F10 estado, bit 1 = F12, bit 2 = F15 proxy, bit 3 = F3, bit 4 = F11
-- Atribución leads→plataforma vía UTM dict (campana_mercadeo → mkt_channel_medium + mkt_platform).
-- Atribución spend→plataforma vía UTM dict campaign_name. Fuente derivada del prefijo del canal.

WITH tig_co AS (
  SELECT
    'CO' AS pais,
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
    t.campana_mercadeo                           AS campana_mercadeo,
    LOWER(IFNULL(sc.email, t.hubspot_owner_id))  AS owner_email_lower,
    REPLACE(LOWER(TRIM(IFNULL(t.estado, ''))), '_', ' ') AS estado_norm,
    LOWER(TRIM(IFNULL(t.calificacion_del_lead_v2, ''))) AS calificacion_lower,
    t.check_a_pricing,
    SAFE_CAST(t.inmobiliaria AS INT64)           AS inmobiliaria_int,
    (t.fecha_primer_asignacion IS NOT NULL OR t.hubspot_owner_id IS NOT NULL) AS ever_owner
  FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` t
  LEFT JOIN `papyrus-data.habi_wh_bi.sc_users_hubspot` sc
    ON t.hubspot_owner_id = CAST(sc.id_segundario AS STRING)
  WHERE t.fecha_creacion IS NOT NULL
    AND DATE(t.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
),

tig_mx AS (
  SELECT
    'MX' AS pais,
    CAST(t.nid AS STRING)                    AS nid,
    DATE(t.fecha_creacion)                   AS d,
    CASE
      WHEN t.fuente_id = 3                       THEN 'WEB'
      WHEN t.fuente_id = 47                      THEN 'Leadforms'
      WHEN t.fuente_id = 7                       THEN 'Habimetro'
      WHEN t.fuente_id = 46                      THEN 'Propiedades'
      WHEN t.fuente_id = 39                      THEN 'Brokers'
      WHEN t.fuente_id = 35                      THEN 'Comercial'
    END                                          AS f,
    t.campana_mercadeo                           AS campana_mercadeo,
    LOWER(IFNULL(sc.email, t.hubspot_owner_id))  AS owner_email_lower,
    REPLACE(LOWER(TRIM(IFNULL(t.estado, ''))), '_', ' ') AS estado_norm,
    LOWER(TRIM(IFNULL(t.calificacion_del_lead_v2, ''))) AS calificacion_lower,
    t.check_a_pricing,
    SAFE_CAST(t.inmobiliaria AS INT64)           AS inmobiliaria_int,
    (t.fecha_primer_asignacion IS NOT NULL OR t.hubspot_owner_id IS NOT NULL) AS ever_owner
  FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` t
  LEFT JOIN `papyrus-data.habi_wh_bi.sc_users_hubspot` sc
    ON t.hubspot_owner_id = CAST(sc.id_segundario AS STRING)
  WHERE t.fecha_creacion IS NOT NULL
    AND DATE(t.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
),

tig AS (
  SELECT * FROM tig_co
  UNION ALL
  SELECT * FROM tig_mx
),

tig_flagged AS (
  SELECT
    pais, nid, d, f, ever_owner,
    IF(estado_norm IN (
      'sin pricing incial', 'sin pricing inicial',
      'no gestionado', 'cierre',
      'no hay suficientes datos para comparar'
    ), 1, 0) AS pf_estado,
    IF(check_a_pricing = 1, 1, 0) AS pf_f12,
    IF(inmobiliaria_int IS NULL OR inmobiliaria_int = 0, 1, 0) AS pf_f15,
    IF(owner_email_lower LIKE '%habi.%', 1, 0) AS pf_f3,
    IF(calificacion_lower NOT IN ('n', 'nh'), 1, 0) AS pf_f11
  FROM tig
  WHERE f IS NOT NULL
),

mart_nids AS (
  SELECT
    CASE WHEN pais = 'colombia' THEN 'CO' WHEN pais = 'mexico' THEN 'MX' END AS pais,
    CAST(nid AS STRING) AS nid
  FROM `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart`
  WHERE pais IN ('colombia', 'mexico')
  GROUP BY 1, 2
),

mart_rows AS (
  SELECT
    f.pais, f.d, f.f,
    CAST(NULL AS INT64)  AS m,
    CAST(NULL AS STRING) AS bucket,
    CAST(NULL AS STRING) AS canal,
    CAST(NULL AS STRING) AS plataforma,
    CAST(NULL AS FLOAT64) AS spend,
    CAST(NULL AS FLOAT64) AS clicks,
    CAST(NULL AS FLOAT64) AS impressions,
    'mart' AS series,
    COUNT(*) AS n
  FROM tig_flagged f
  INNER JOIN mart_nids m ON f.pais = m.pais AND f.nid = m.nid
  GROUP BY 1, 2, 3
),

ever_rows AS (
  SELECT
    pais, d, f,
    (pf_estado * 1 + pf_f12 * 2 + pf_f15 * 4 + pf_f3 * 8 + pf_f11 * 16) AS m,
    CAST(NULL AS STRING) AS bucket,
    CAST(NULL AS STRING) AS canal,
    CAST(NULL AS STRING) AS plataforma,
    CAST(NULL AS FLOAT64) AS spend,
    CAST(NULL AS FLOAT64) AS clicks,
    CAST(NULL AS FLOAT64) AS impressions,
    'ever' AS series,
    COUNT(*) AS n
  FROM tig_flagged
  WHERE ever_owner
  GROUP BY 1, 2, 3, 4
),

gap_pre AS (
  SELECT
    t.pais, t.d, t.f,
    CASE
      WHEN t.pf_estado = 0 THEN 'F7-F10'
      WHEN t.pf_f12 = 0    THEN 'F12'
      WHEN t.pf_f15 = 0    THEN 'F15'
      WHEN t.pf_f3 = 0     THEN 'F3'
      WHEN t.pf_f11 = 0    THEN 'F11'
      ELSE 'Otro'
    END AS bucket
  FROM tig_flagged t
  LEFT JOIN mart_nids m ON t.pais = m.pais AND t.nid = m.nid
  WHERE t.ever_owner
    AND m.nid IS NULL
),

gap_rows AS (
  SELECT
    pais, d, f,
    CAST(NULL AS INT64)  AS m,
    bucket,
    CAST(NULL AS STRING) AS canal,
    CAST(NULL AS STRING) AS plataforma,
    CAST(NULL AS FLOAT64) AS spend,
    CAST(NULL AS FLOAT64) AS clicks,
    CAST(NULL AS FLOAT64) AS impressions,
    'gap' AS series,
    COUNT(*) AS n
  FROM gap_pre
  GROUP BY 1, 2, 3, 5
),

-- UTM dictionaries deduplicated by key (campana_mercadeo_original OR mkt_campaign_name)
utm_co_orig AS (
  SELECT
    LOWER(TRIM(campana_mercadeo_original))                        AS camp_key,
    ANY_VALUE(mkt_channel_medium)                                 AS canal_raw,
    ANY_VALUE(mkt_platform)                                       AS plataforma_raw
  FROM `sellers-main-prod.bi_co.registro_unico_utm_mkt_colombia`
  WHERE campana_mercadeo_original IS NOT NULL
    AND mkt_platform IS NOT NULL AND mkt_platform != ''
  GROUP BY 1
),
utm_co_camp AS (
  SELECT
    LOWER(TRIM(mkt_campaign_name))                                AS camp_key,
    ANY_VALUE(mkt_channel_medium)                                 AS canal_raw,
    ANY_VALUE(mkt_platform)                                       AS plataforma_raw
  FROM `sellers-main-prod.bi_co.registro_unico_utm_mkt_colombia`
  WHERE mkt_campaign_name IS NOT NULL
    AND mkt_platform IS NOT NULL AND mkt_platform != ''
  GROUP BY 1
),
utm_mx_orig AS (
  SELECT
    LOWER(TRIM(campana_mercadeo_original))                        AS camp_key,
    ANY_VALUE(mkt_channel_medium)                                 AS canal_raw,
    ANY_VALUE(mkt_platform)                                       AS plataforma_raw
  FROM `sellers-main-prod.bi_mx.registro_unico_utm_mkt_mexico`
  WHERE campana_mercadeo_original IS NOT NULL
    AND mkt_platform IS NOT NULL AND mkt_platform != ''
  GROUP BY 1
),
utm_mx_camp AS (
  SELECT
    LOWER(TRIM(mkt_campaign_name))                                AS camp_key,
    ANY_VALUE(mkt_channel_medium)                                 AS canal_raw,
    ANY_VALUE(mkt_platform)                                       AS plataforma_raw
  FROM `sellers-main-prod.bi_mx.registro_unico_utm_mkt_mexico`
  WHERE mkt_campaign_name IS NOT NULL
    AND mkt_platform IS NOT NULL AND mkt_platform != ''
  GROUP BY 1
),

-- Leads atribuidos a (canal, plataforma) vía campana_mercadeo
leads_attr_co AS (
  SELECT
    t.pais, t.d, t.f AS f, u.canal_raw AS canal,
    CASE
      WHEN LOWER(u.plataforma_raw) = 'tiktok'     THEN 'TikTok'
      WHEN LOWER(u.plataforma_raw) = 'google'     THEN 'Google'
      WHEN LOWER(u.plataforma_raw) = 'facebook'   THEN 'Facebook'
      WHEN LOWER(u.plataforma_raw) = 'bing'       THEN 'Bing'
      WHEN LOWER(u.plataforma_raw) = 'instagram'  THEN 'Instagram'
      WHEN LOWER(u.plataforma_raw) = 'youtube'    THEN 'YouTube'
      WHEN LOWER(u.plataforma_raw) = 'linkedin'   THEN 'LinkedIn'
      ELSE u.plataforma_raw
    END AS plataforma,
    COUNT(*) AS n
  FROM tig_co t
  JOIN utm_co_orig u ON LOWER(TRIM(t.campana_mercadeo)) = u.camp_key
  WHERE t.f IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5
),
leads_attr_mx AS (
  SELECT
    t.pais, t.d, t.f AS f, u.canal_raw AS canal,
    CASE
      WHEN LOWER(u.plataforma_raw) = 'tiktok'     THEN 'TikTok'
      WHEN LOWER(u.plataforma_raw) = 'google'     THEN 'Google'
      WHEN LOWER(u.plataforma_raw) = 'facebook'   THEN 'Facebook'
      WHEN LOWER(u.plataforma_raw) = 'bing'       THEN 'Bing'
      WHEN LOWER(u.plataforma_raw) = 'instagram'  THEN 'Instagram'
      WHEN LOWER(u.plataforma_raw) = 'youtube'    THEN 'YouTube'
      WHEN LOWER(u.plataforma_raw) = 'linkedin'   THEN 'LinkedIn'
      ELSE u.plataforma_raw
    END AS plataforma,
    COUNT(*) AS n
  FROM tig_mx t
  JOIN utm_mx_orig u ON LOWER(TRIM(t.campana_mercadeo)) = u.camp_key
  WHERE t.f IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5
),

leads_attr_rows AS (
  SELECT
    pais, d, f,
    CAST(NULL AS INT64)  AS m,
    CAST(NULL AS STRING) AS bucket,
    canal, plataforma,
    CAST(NULL AS FLOAT64) AS spend,
    CAST(NULL AS FLOAT64) AS clicks,
    CAST(NULL AS FLOAT64) AS impressions,
    'leads_attr' AS series,
    n
  FROM (
    SELECT * FROM leads_attr_co
    UNION ALL
    SELECT * FROM leads_attr_mx
  )
),

-- Spend atribuido a (canal, plataforma) vía campaign_name. Fuente derivada del prefijo del canal.
spend_co AS (
  SELECT
    'CO' AS pais,
    i.date AS d,
    CASE
      WHEN u.canal_raw LIKE 'WEB%'              THEN 'WEB'
      WHEN u.canal_raw LIKE 'Estudio Inmueble%' THEN 'Habimetro'
      WHEN LOWER(u.canal_raw) LIKE 'lead_forms%' OR LOWER(u.canal_raw) LIKE 'lead forms%' THEN 'Leadforms'
      WHEN u.canal_raw LIKE 'CRM%'              THEN 'CRM'
      WHEN u.canal_raw LIKE 'Broker%'           THEN 'Brokers'
      WHEN u.canal_raw LIKE 'Comercial%'        THEN 'Comercial'
    END AS f,
    u.canal_raw AS canal,
    CASE
      WHEN LOWER(u.plataforma_raw) = 'tiktok'     THEN 'TikTok'
      WHEN LOWER(u.plataforma_raw) = 'google'     THEN 'Google'
      WHEN LOWER(u.plataforma_raw) = 'facebook'   THEN 'Facebook'
      WHEN LOWER(u.plataforma_raw) = 'bing'       THEN 'Bing'
      WHEN LOWER(u.plataforma_raw) = 'instagram'  THEN 'Instagram'
      WHEN LOWER(u.plataforma_raw) = 'youtube'    THEN 'YouTube'
      WHEN LOWER(u.plataforma_raw) = 'linkedin'   THEN 'LinkedIn'
      ELSE u.plataforma_raw
    END AS plataforma,
    SUM(IFNULL(i.spend, 0))       AS spend,
    SUM(IFNULL(i.clicks, 0))      AS clicks,
    SUM(IFNULL(i.impressions, 0)) AS impressions
  FROM `papyrus-data.habi_wh_bi.resumen_inversiones_mkt_co` i
  JOIN utm_co_camp u ON LOWER(TRIM(i.campana)) = u.camp_key
  WHERE i.date >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
  GROUP BY 1, 2, 3, 4, 5
  HAVING f IS NOT NULL
),
spend_mx AS (
  SELECT
    'MX' AS pais,
    i.date AS d,
    CASE
      WHEN u.canal_raw LIKE 'WEB%'              THEN 'WEB'
      WHEN u.canal_raw LIKE 'Estudio Inmueble%' THEN 'Habimetro'
      WHEN LOWER(u.canal_raw) LIKE 'lead_forms%' OR LOWER(u.canal_raw) LIKE 'lead forms%' THEN 'Leadforms'
      WHEN u.canal_raw LIKE 'Propiedades%'      THEN 'Propiedades'
      WHEN u.canal_raw LIKE 'Broker%'           THEN 'Brokers'
      WHEN u.canal_raw LIKE 'Comercial%'        THEN 'Comercial'
    END AS f,
    u.canal_raw AS canal,
    CASE
      WHEN LOWER(u.plataforma_raw) = 'tiktok'     THEN 'TikTok'
      WHEN LOWER(u.plataforma_raw) = 'google'     THEN 'Google'
      WHEN LOWER(u.plataforma_raw) = 'facebook'   THEN 'Facebook'
      WHEN LOWER(u.plataforma_raw) = 'bing'       THEN 'Bing'
      WHEN LOWER(u.plataforma_raw) = 'instagram'  THEN 'Instagram'
      WHEN LOWER(u.plataforma_raw) = 'youtube'    THEN 'YouTube'
      WHEN LOWER(u.plataforma_raw) = 'linkedin'   THEN 'LinkedIn'
      ELSE u.plataforma_raw
    END AS plataforma,
    SUM(IFNULL(i.spend, 0))       AS spend,
    SUM(IFNULL(i.clicks, 0))      AS clicks,
    SUM(IFNULL(i.impressions, 0)) AS impressions
  FROM `papyrus-data-mx.habi_wh_bi.resumen_inversiones_mkt_mx` i
  JOIN utm_mx_camp u ON LOWER(TRIM(i.campana)) = u.camp_key
  WHERE i.date >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
  GROUP BY 1, 2, 3, 4, 5
  HAVING f IS NOT NULL
),

spend_rows AS (
  SELECT
    pais, d, f,
    CAST(NULL AS INT64)  AS m,
    CAST(NULL AS STRING) AS bucket,
    canal, plataforma,
    spend, clicks, impressions,
    'spend' AS series,
    CAST(NULL AS INT64) AS n
  FROM (
    SELECT * FROM spend_co
    UNION ALL
    SELECT * FROM spend_mx
  )
)

SELECT * FROM mart_rows
UNION ALL SELECT * FROM ever_rows
UNION ALL SELECT * FROM gap_rows
UNION ALL SELECT * FROM leads_attr_rows
UNION ALL SELECT * FROM spend_rows
ORDER BY pais, series, d, f
