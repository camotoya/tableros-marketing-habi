-- Tablero creativo-pamela: funnel cohort de Pamela Longoria vs Web Paid Facebook MX (universo)
-- Universo: leads MX cuyo `tig.campana_mercadeo` mapea a (mkt_channel_medium='WEB Paid', mkt_platform='Facebook')
-- Cohorte por fecha_creacion del lead, desde 2026-04-17. Día actual excluido.
-- Pamela: subset de leads con utm_content='pamela_longoria' en deal_utm.
-- MM (Market Maker) vs Inmo: funnels independientes sobre el 100% del cohort (t_mm = t_inmo = t).
-- Calificó MM = state_id IN (20,63) en habi_db_history_state. Calificó Inmo = state_id=20 en habi_db_history_state_real_estate.
-- Inmo solo llega hasta 'Primer asignacion' — Cita/Visita/Aprobado/Aceptó/Cierre NO aplican (forzados a 0).
-- Inversión en USD desde ads_insights_region. Spend FB Paid total = campañas del dict UTM. Spend Pamela = ad_name LIKE 'Pamela_Longoria%'.

WITH dict AS (
  SELECT campana_mercadeo_original
  FROM `sellers-main-prod.bi_mx.registro_unico_utm_mkt_mexico`
  WHERE mkt_channel_medium = 'WEB Paid' AND mkt_platform = 'Facebook'
),

pamela_deals AS (
  SELECT DISTINCT deal_id
  FROM `papyrus-data-mx.habi_data_analytics.deal_utm`
  WHERE LOWER(utm_content) = 'pamela_longoria' AND deal_id IS NOT NULL
),

base AS (
  SELECT
    tig.nid,
    tig.id_negocio AS deal_id,
    DATE(tig.fecha_creacion) AS fecha,
    IF(pd.deal_id IS NOT NULL, 1, 0) AS is_pamela
  FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` tig
  INNER JOIN dict ON dict.campana_mercadeo_original = tig.campana_mercadeo
  LEFT JOIN pamela_deals pd ON pd.deal_id = tig.id_negocio
  WHERE tig.fecha_creacion IS NOT NULL
    AND DATE(tig.fecha_creacion) >= '2026-04-17'
    AND DATE(tig.fecha_creacion) < CURRENT_DATE()
    AND tig.nid IS NOT NULL
),

mm_cal AS (
  SELECT deal_id, MIN(DATE(date_create)) AS ev_date
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state`
  WHERE state_id IN (20, 63) AND deal_id IS NOT NULL
  GROUP BY deal_id
),

inmo_cal AS (
  SELECT deal_id, MIN(DATE(date_create)) AS ev_date
  FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state_real_estate`
  WHERE state_id = 20 AND deal_id IS NOT NULL
  GROUP BY deal_id
),

stages AS (
  SELECT
    nid,
    MIN(IF(valor IN ('Primer asignacion'), DATE(fecha), NULL)) AS asg_date,
    MIN(IF(valor IN ('Cita Agendada','Cita Agendada (hubspot)'), DATE(fecha), NULL)) AS cit_date,
    MIN(IF(valor IN ('Visita Efectuada','Visita Efectuada (hubspot)'), DATE(fecha), NULL)) AS vis_date,
    MIN(IF(valor IN ('Aprobado General','Primer inmueble aprobado'), DATE(fecha), NULL)) AS apr_date,
    MIN(IF(valor IN ('Acepto Oferta - Pendiente firma'), DATE(fecha), NULL)) AS acp_date,
    MIN(IF(valor = 'Cierre - Comprado', DATE(fecha), NULL)) AS cie_date
  FROM `sellers-main-prod.bi_mx.seguimiento_funnel_mex`
  WHERE nid IS NOT NULL
  GROUP BY nid
),

enriched AS (
  SELECT
    b.nid, b.fecha, b.is_pamela,
    m.ev_date AS mm_cal_date,
    i.ev_date AS inmo_cal_date,
    s.asg_date, s.cit_date, s.vis_date, s.apr_date, s.acp_date, s.cie_date
  FROM base b
  LEFT JOIN mm_cal m ON m.deal_id = b.deal_id
  LEFT JOIN inmo_cal i ON i.deal_id = b.deal_id
  LEFT JOIN stages s ON s.nid = b.nid
),

-- Spend USD desde ads_insights_region (granularidad ad × región × fecha).
-- FB Paid total: spend de TODAS las campañas en el dict UTM (mismo universo que el cohort).
-- Pamela: spend de TODOS los ads cuyo ad_name LIKE 'Pamela_Longoria%' (incluye Pamela_Longoria, _colab, _colab - Copia).
spend_fbp AS (
  SELECT date_start AS d, SUM(air.spend) AS spend
  FROM `sellers-main-prod.facebook_ads_data_mx.ads_insights_region` air
  INNER JOIN dict ON dict.campana_mercadeo_original = air.campaign_name
  WHERE air.date_start >= '2026-04-17' AND air.date_start < CURRENT_DATE()
  GROUP BY d
),
spend_pml AS (
  SELECT date_start AS d, SUM(spend) AS spend
  FROM `sellers-main-prod.facebook_ads_data_mx.ads_insights_region`
  WHERE LOWER(ad_name) LIKE 'pamela_longoria%'
    AND date_start >= '2026-04-17' AND date_start < CURRENT_DATE()
  GROUP BY d
),

-- Funnel del universo total Web Paid FB
fbp_funnel AS (
  SELECT
    fecha AS d,
    'fbp' AS u,
    COUNT(DISTINCT nid) AS t,
    COUNTIF(mm_cal_date IS NOT NULL OR inmo_cal_date IS NOT NULL) AS cal,
    COUNTIF(asg_date IS NOT NULL) AS asg,
    COUNTIF(cit_date IS NOT NULL) AS cit,
    COUNTIF(vis_date IS NOT NULL) AS vis,
    COUNTIF(apr_date IS NOT NULL) AS apr,
    COUNTIF(acp_date IS NOT NULL) AS acp,
    COUNTIF(cie_date IS NOT NULL) AS cie,
    COUNT(DISTINCT nid) AS t_mm,
    COUNTIF(mm_cal_date IS NOT NULL) AS cal_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND asg_date IS NOT NULL) AS asg_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND cit_date IS NOT NULL) AS cit_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND vis_date IS NOT NULL) AS vis_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND apr_date IS NOT NULL) AS apr_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND acp_date IS NOT NULL) AS acp_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND cie_date IS NOT NULL) AS cie_mm,
    COUNT(DISTINCT nid) AS t_inmo,
    COUNTIF(inmo_cal_date IS NOT NULL) AS cal_inmo,
    COUNTIF(inmo_cal_date IS NOT NULL AND asg_date IS NOT NULL) AS asg_inmo,
    -- Inmo no aplica para etapas avanzadas — forzar 0
    0 AS cit_inmo, 0 AS vis_inmo, 0 AS apr_inmo, 0 AS acp_inmo, 0 AS cie_inmo
  FROM enriched
  GROUP BY d
),

pml_funnel AS (
  SELECT
    fecha AS d,
    'pml' AS u,
    COUNT(DISTINCT nid) AS t,
    COUNTIF(mm_cal_date IS NOT NULL OR inmo_cal_date IS NOT NULL) AS cal,
    COUNTIF(asg_date IS NOT NULL) AS asg,
    COUNTIF(cit_date IS NOT NULL) AS cit,
    COUNTIF(vis_date IS NOT NULL) AS vis,
    COUNTIF(apr_date IS NOT NULL) AS apr,
    COUNTIF(acp_date IS NOT NULL) AS acp,
    COUNTIF(cie_date IS NOT NULL) AS cie,
    COUNT(DISTINCT nid) AS t_mm,
    COUNTIF(mm_cal_date IS NOT NULL) AS cal_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND asg_date IS NOT NULL) AS asg_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND cit_date IS NOT NULL) AS cit_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND vis_date IS NOT NULL) AS vis_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND apr_date IS NOT NULL) AS apr_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND acp_date IS NOT NULL) AS acp_mm,
    COUNTIF(mm_cal_date IS NOT NULL AND cie_date IS NOT NULL) AS cie_mm,
    COUNT(DISTINCT nid) AS t_inmo,
    COUNTIF(inmo_cal_date IS NOT NULL) AS cal_inmo,
    COUNTIF(inmo_cal_date IS NOT NULL AND asg_date IS NOT NULL) AS asg_inmo,
    0 AS cit_inmo, 0 AS vis_inmo, 0 AS apr_inmo, 0 AS acp_inmo, 0 AS cie_inmo
  FROM enriched
  WHERE is_pamela = 1
  GROUP BY d
),

-- Date spine: un row por (día, universo) en todo el rango activo del experimento.
-- Garantiza que días con spend pero sin leads (o viceversa) aparezcan en el output.
date_spine AS (
  SELECT d FROM UNNEST(GENERATE_DATE_ARRAY('2026-04-17', DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY))) AS d
),
spine AS (
  SELECT s.d, u FROM date_spine s, UNNEST(['fbp','pml']) AS u
),
funnel_all AS (
  SELECT * FROM fbp_funnel
  UNION ALL
  SELECT * FROM pml_funnel
)

SELECT
  CAST(s.d AS STRING) AS d,
  s.u,
  ROUND(IFNULL(IF(s.u='fbp', sf.spend, sp.spend), 0), 2) AS spend,
  IFNULL(f.t, 0) AS t,
  IFNULL(f.cal, 0) AS cal,
  IFNULL(f.asg, 0) AS asg,
  IFNULL(f.cit, 0) AS cit,
  IFNULL(f.vis, 0) AS vis,
  IFNULL(f.apr, 0) AS apr,
  IFNULL(f.acp, 0) AS acp,
  IFNULL(f.cie, 0) AS cie,
  IFNULL(f.t_mm, 0) AS t_mm,
  IFNULL(f.cal_mm, 0) AS cal_mm,
  IFNULL(f.asg_mm, 0) AS asg_mm,
  IFNULL(f.cit_mm, 0) AS cit_mm,
  IFNULL(f.vis_mm, 0) AS vis_mm,
  IFNULL(f.apr_mm, 0) AS apr_mm,
  IFNULL(f.acp_mm, 0) AS acp_mm,
  IFNULL(f.cie_mm, 0) AS cie_mm,
  IFNULL(f.t_inmo, 0) AS t_inmo,
  IFNULL(f.cal_inmo, 0) AS cal_inmo,
  IFNULL(f.asg_inmo, 0) AS asg_inmo,
  IFNULL(f.cit_inmo, 0) AS cit_inmo,
  IFNULL(f.vis_inmo, 0) AS vis_inmo,
  IFNULL(f.apr_inmo, 0) AS apr_inmo,
  IFNULL(f.acp_inmo, 0) AS acp_inmo,
  IFNULL(f.cie_inmo, 0) AS cie_inmo
FROM spine s
LEFT JOIN funnel_all f ON f.u = s.u AND f.d = s.d
LEFT JOIN spend_fbp sf ON s.u = 'fbp' AND sf.d = s.d
LEFT JOIN spend_pml sp ON s.u = 'pml' AND sp.d = s.d
ORDER BY s.d, s.u
