-- PMAX MX — desglose de leads SIN precio (hd.ask_price IS NULL) por estado actual.
-- Mismos filtros que query.sql (mismas UTMs, misma ventana). Una fila por (día, utm, estado).
-- Output: dia, utm, state_id, state_name, n
SELECT
  CAST(DATE(t.fecha_creacion) AS STRING) AS dia,
  t.campana_mercadeo AS utm,
  pd.last_state_id AS state_id,
  COALESCE(cat.estado, CONCAT('state_', CAST(pd.last_state_id AS STRING))) AS state_name,
  COUNT(*) AS n
FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` t
LEFT JOIN `sellers-main-prod.hubspot.deals` hd
  ON hd.nid = t.nid
LEFT JOIN `sellers-main-prod.mx_rds_staging.habi_db_property_deal` pd
  ON pd.id = t.id_negocio
LEFT JOIN `sellers-main-prod.co_rds_staging.habi_db_tabla_estados` cat
  ON cat.id = pd.last_state_id
WHERE DATE(t.fecha_creacion) >= '2025-01-01'
  AND t.campana_mercadeo IN (
    'aw_tuhabi_mx_performance_max_nal_max_conv_2',
    'aw_tuhabi_mx_performance_max_nal_max_conv_price',
    'aw_tuhabi_mx_do_performance_max_nal_ao',
    'bing_tuhabi_mx_do_performance_max_nal_ao',
    'aw_tuhabi_mx_do_sem_performance_max_nal_ao',
    'aw_tuhabi_mx_performance_max_nal_max_conv'
  )
  AND hd.ask_price IS NULL
GROUP BY dia, utm, state_id, state_name
ORDER BY dia, utm, n DESC
