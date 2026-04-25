SELECT
  CAST(DATE(t.fecha_creacion) AS STRING) AS dia,
  t.campana_mercadeo AS utm,
  COUNTIF(hd.ask_price IS NOT NULL) AS con_precio,
  COUNTIF(hd.ask_price IS NULL)     AS sin_precio
FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` t
LEFT JOIN `sellers-main-prod.hubspot.deals` hd
  ON hd.nid = t.nid
WHERE DATE(t.fecha_creacion) >= '2025-01-01'
  AND t.campana_mercadeo IN (
    'aw_tuhabi_mx_performance_max_nal_max_conv_2',
    'aw_tuhabi_mx_performance_max_nal_max_conv_price',
    'aw_tuhabi_mx_do_performance_max_nal_ao',
    'bing_tuhabi_mx_do_performance_max_nal_ao',
    'aw_tuhabi_mx_do_sem_performance_max_nal_ao',
    'aw_tuhabi_mx_performance_max_nal_max_conv'
  )
GROUP BY dia, utm
ORDER BY dia, utm
