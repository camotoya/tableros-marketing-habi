-- funnel-fuentes/query.sql
-- Funnel de leads CO: Web habi.co | Help-to-sell | Ayuda Venta (Inmo).
-- Output: filas (date, source, stage, count) que build_data.py pivotea a data.json.
-- Ventana: ultimos 180 dias (excluye hoy). Timezone: America/Bogota.

WITH params AS (
  SELECT
    DATE_SUB(CURRENT_DATE('America/Bogota'), INTERVAL 180 DAY) AS start_date,
    CURRENT_DATE('America/Bogota') AS end_date_exclusive
),

pages_classified AS (
  SELECT
    DATE(timestamp, 'America/Bogota') AS d,
    anonymous_id,
    context_page_path AS path,
    context_page_url AS url,
    context_page_referrer AS ref,
    name AS event_name,
    timestamp AS ts,
    CASE
      WHEN context_page_url LIKE '%utm_content=help_to_sell%'
        OR context_page_referrer LIKE '%ayudaventas-habi-web.vercel.app%'
      THEN 'help_to_sell'
      ELSE 'web_puro'
    END AS source
  FROM `sellers-main-prod.co_segment_profiles.pages`, params
  WHERE context_page_path LIKE '/formulario-inmueble%'
    AND DATE(timestamp, 'America/Bogota') >= params.start_date
    AND DATE(timestamp, 'America/Bogota') < params.end_date_exclusive
    AND anonymous_id IS NOT NULL
),

stages_daily AS (
  WITH stage_map AS (
    SELECT path, stage FROM UNNEST([
      STRUCT('/formulario-inmueble/direccion' AS path, 'direccion' AS stage),
      ('/formulario-inmueble/inmuebles-zona', 'zona'),
      ('/formulario-inmueble/confirmar-ubicacion', 'zona'),
      ('/formulario-inmueble/sugerencias', 'zona'),
      ('/formulario-inmueble/datos-inmueble', 'datos_inmueble'),
      ('/formulario-inmueble/contacto', 'contacto'),
      ('/formulario-inmueble/caracteristicas', 'caracteristicas'),
      ('/formulario-inmueble/ultimos-detalles', 'ultimos_detalles'),
      ('/formulario-inmueble/felicitaciones', 'felicitaciones')
    ])
  )
  SELECT
    p.d,
    p.source,
    sm.stage,
    COUNT(DISTINCT p.anonymous_id) AS n
  FROM pages_classified p
  JOIN stage_map sm ON sm.path = p.path
  GROUP BY p.d, p.source, sm.stage
),

uuid_chain AS (
  -- Para cada anonymous_id que llego a /felicitaciones, resolver el deal final via chain UUID.
  -- Una fila por (anonymous_id, source, fecha_felicitaciones, fecha_creacion_lead) cuando hay match.
  SELECT
    fp.d_form,
    fp.source,
    fp.anonymous_id,
    sc.backbone_uuid,
    b.deal_uuid,
    pd.nid,
    DATE(g.fecha_creacion) AS d_lead
  FROM (
    SELECT d AS d_form, source, anonymous_id
    FROM pages_classified
    WHERE path = '/formulario-inmueble/felicitaciones'
    GROUP BY d_form, source, anonymous_id
  ) fp
  LEFT JOIN `sellers-main-prod.co_segment_profiles.select_content` sc
    ON sc.anonymous_id = fp.anonymous_id
    AND DATE(sc.timestamp, 'America/Bogota') = fp.d_form
  LEFT JOIN `sellers-main-prod.top_funnel.web_global_api_business` b
    ON b.uuid = sc.backbone_uuid
  LEFT JOIN `sellers-main-prod.co_rds_staging.habi_db_tabla_negocio_inmueble` pd
    ON pd.uuid = b.deal_uuid
  LEFT JOIN `papyrus-data.habi_wh_bi.tabla_inmuebles_general` g
    ON g.nid = pd.nid
),

leads_ab_daily AS (
  -- Cuenta de leads creados (en HubSpot/CRM) cuyo /felicitaciones cayo en el mismo dia Bogota.
  SELECT
    d_form AS d,
    source,
    COUNT(DISTINCT nid) AS n
  FROM uuid_chain
  WHERE nid IS NOT NULL
    AND d_lead = d_form
  GROUP BY d, source
),

completions_no_deal_daily AS (
  -- Anonymous_ids que llegaron a /felicitaciones pero el chain no resolvio un deal en el mismo dia.
  SELECT
    d_form AS d,
    source,
    COUNT(DISTINCT anonymous_id) AS n
  FROM uuid_chain
  WHERE nid IS NULL OR d_lead IS NULL OR d_lead != d_form
  GROUP BY d, source
),

leads_c_daily AS (
  -- Fuente C (Ayuda Venta - form Inmo en vercel). Sin etapas, solo lead final.
  SELECT
    DATE(createdate, 'America/Bogota') AS d,
    'ayuda_venta' AS source,
    'lead_hubspot' AS stage,
    COUNT(*) AS n
  FROM `sellers-main-prod.hubspot.deals`, params
  WHERE sub_fuente = 'Ayuda Venta'
    AND DATE(createdate, 'America/Bogota') >= params.start_date
    AND DATE(createdate, 'America/Bogota') < params.end_date_exclusive
  GROUP BY d
)

SELECT d, source, stage, n FROM stages_daily
UNION ALL
SELECT d, source, 'lead_hubspot' AS stage, n FROM leads_ab_daily
UNION ALL
SELECT d, source, stage, n FROM leads_c_daily
UNION ALL
SELECT d, source, 'completions_no_deal' AS stage, n FROM completions_no_deal_daily
ORDER BY d DESC, source, stage;
