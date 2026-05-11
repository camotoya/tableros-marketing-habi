-- Asignados por fecha de creación del lead (CO) — directo del WBR mart
-- Output: una fila por día con count de asignados cuyo lead se creó ese día.
-- Window: últimos 540 días (18 meses para soportar granularidad mes con 18 períodos).
-- Bucket axis: fecha_creacion de tabla_inmuebles_general (join por nid)

SELECT
  DATE(tig.fecha_creacion) AS d,
  COUNT(*) AS n
FROM `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart` mart
INNER JOIN `papyrus-data.habi_wh_bi.tabla_inmuebles_general` tig
  ON mart.nid = tig.nid
WHERE mart.pais = 'colombia'
  AND tig.fecha_creacion IS NOT NULL
  AND DATE(tig.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 540 DAY)
GROUP BY 1
ORDER BY 1
