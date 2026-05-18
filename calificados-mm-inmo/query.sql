-- Calificados MM e Inmo (CO + MX) — cohort por fecha de registro
-- Output: una fila por (pais, d, fuente) con (d = fecha de creación, granularidad día):
--   calif_inmo : leads de la cohort que llegaron a state_id=20 en Inmo history
--   calif_mm   : leads de la cohort que llegaron a state_id IN (20, 63) en MM history
--   calif_both : leads que cumplen ambas
--
-- Ratio target (frontend): calif_both / calif_mm  (% de MM-calificados que también pasan Inmo)
-- Frontend bucketea por día / semana / mes (selector).
-- Window: últimos 364 días (52 semanas), excluye día actual.
-- Importante: Inmo history CO arranca 2026-03-12; días previos tendrán calif_inmo=0
-- aunque la cohort registró leads — no es bug, es ausencia de data histórica.

WITH
  tig_co AS (
    SELECT
      CAST(t.negocio_id AS INT64) AS negocio_id,
      DATE(t.fecha_creacion) AS d,
      CASE
        WHEN t.fuente_id = 3                       THEN 'WEB'
        WHEN t.fuente_id IN (47, 37, 41, 42)       THEN 'Leadforms'
        WHEN t.fuente_id = 7                       THEN 'Habimetro'
        WHEN t.fuente_id = 20                      THEN 'CRM'
        WHEN t.fuente_id = 39                      THEN 'Brokers'
        WHEN t.fuente_id = 35                      THEN 'Comercial'
      END AS fuente
    FROM `papyrus-data.habi_wh_bi.tabla_inmuebles_general` t
    WHERE t.fecha_creacion IS NOT NULL
      AND t.negocio_id IS NOT NULL
      AND t.fuente_id IN (3, 7, 20, 35, 39, 47, 37, 41, 42)
      AND DATE(t.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 364 DAY)
      AND DATE(t.fecha_creacion) <  CURRENT_DATE()
  ),
  mm_calif_co AS (
    SELECT DISTINCT negocio_id
    FROM `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
    WHERE estado_id IN (20, 63)
  ),
  inmo_calif_co AS (
    SELECT DISTINCT deal_id AS negocio_id
    FROM `sellers-main-prod.co_rds_staging.habi_db_history_state_real_estate`
    WHERE state_id = 20
  ),
  co_agg AS (
    SELECT
      'CO' AS pais,
      CAST(t.d AS STRING) AS d,
      t.fuente,
      COUNTIF(im.negocio_id IS NOT NULL)                                AS calif_inmo,
      COUNTIF(mm.negocio_id IS NOT NULL)                                AS calif_mm,
      COUNTIF(mm.negocio_id IS NOT NULL AND im.negocio_id IS NOT NULL)  AS calif_both,
      COUNT(*)                                                           AS reg
    FROM tig_co t
    LEFT JOIN mm_calif_co   mm ON t.negocio_id = mm.negocio_id
    LEFT JOIN inmo_calif_co im ON t.negocio_id = im.negocio_id
    WHERE t.fuente IS NOT NULL
    GROUP BY 1, 2, 3
  ),

  tig_mx AS (
    SELECT
      CAST(t.id_negocio AS INT64) AS negocio_id,
      DATE(t.fecha_creacion) AS d,
      CASE
        WHEN t.fuente_id = 3                       THEN 'WEB'
        WHEN t.fuente_id = 47                      THEN 'Leadforms'
        WHEN t.fuente_id = 7                       THEN 'Habimetro'
        WHEN t.fuente_id = 46                      THEN 'Propiedades'
        WHEN t.fuente_id = 39                      THEN 'Brokers'
        WHEN t.fuente_id = 35                      THEN 'Comercial'
      END AS fuente
    FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` t
    WHERE t.fecha_creacion IS NOT NULL
      AND t.id_negocio IS NOT NULL
      AND t.fuente_id IN (3, 7, 35, 39, 46, 47)
      AND DATE(t.fecha_creacion) >= DATE_SUB(CURRENT_DATE(), INTERVAL 364 DAY)
      AND DATE(t.fecha_creacion) <  CURRENT_DATE()
  ),
  mm_calif_mx AS (
    SELECT DISTINCT deal_id AS negocio_id
    FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state`
    WHERE state_id IN (20, 63)
  ),
  inmo_calif_mx AS (
    SELECT DISTINCT deal_id AS negocio_id
    FROM `sellers-main-prod.mx_rds_staging.habi_db_history_state_real_estate`
    WHERE state_id = 20
  ),
  mx_agg AS (
    SELECT
      'MX' AS pais,
      CAST(t.d AS STRING) AS d,
      t.fuente,
      COUNTIF(im.negocio_id IS NOT NULL)                                AS calif_inmo,
      COUNTIF(mm.negocio_id IS NOT NULL)                                AS calif_mm,
      COUNTIF(mm.negocio_id IS NOT NULL AND im.negocio_id IS NOT NULL)  AS calif_both,
      COUNT(*)                                                           AS reg
    FROM tig_mx t
    LEFT JOIN mm_calif_mx   mm ON t.negocio_id = mm.negocio_id
    LEFT JOIN inmo_calif_mx im ON t.negocio_id = im.negocio_id
    WHERE t.fuente IS NOT NULL
    GROUP BY 1, 2, 3
  )

SELECT * FROM co_agg
UNION ALL
SELECT * FROM mx_agg
ORDER BY pais, d, fuente
