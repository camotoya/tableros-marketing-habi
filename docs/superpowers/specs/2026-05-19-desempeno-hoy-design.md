# Tablero "Desempeño hoy" — diseño

**Fecha:** 2026-05-19
**Autor:** Camilo Otoya + Jean-Claude
**Estado:** aprobado para implementación

## Objetivo

Tablero live del repo `tableros-marketing-habi` que muestra el desempeño del día actual hora-por-hora de **calificados** (primer entrance a estado 20 o 63 del funnel MM), con selectores de **país** (CO / MX) y **fuente** (multi-select), comparado contra el mismo día de la semana pasada y el promedio de los últimos 4 mismos días de semana.

Sirve a marketing/growth para detectar caídas o picos del día sin esperar al reporte diario.

## Alcance V1

Incluye:
- Una sola métrica: **calificados MM** (estados 20/63, primer entrance).
- 2 países: CO y MX, single-select.
- 6 fuentes oficiales, chips multi-select con "Todas" como atajo.
- 3 series: hoy / hace 7 días / promedio últimos 4 mismos días de semana.
- 2 vistas: acumulado del día / volumen por hora (toggle).
- Refresh automático cada 15 min vía GitHub Actions + botón "recargar" manual en la UI.

No incluye (Fase 2 si llega):
- Registros (fecha_creacion) y Asignados (fecha_primer_asignacion) como series adicionales.
- Drill-down por canal / plataforma.
- Funnel Inmo (`history_state_real_estate`).
- Meta del sheet OKR como referencia.
- Trigger manual del workflow desde la UI (requeriría PAT).

## Arquitectura

```
~/habi/tableros-marketing/desempeno-hoy/
├── index.html              ← UI standalone, dark theme, Chart.js CDN
├── query.sql               ← query parametrizable por país y TZ
└── data.json               ← auto-update */15 * * * * UTC

scripts/desempeno_hoy_to_json.py    ← transforma BQ output → shape final
.github/workflows/desempeno-hoy.yml ← workflow separado, cron 15 min
```

**Por qué workflow separado:** el consolidado (`update-data.yml`) hace 1 commit/día con muchos archivos. Mezclar una cadencia de 15 min ahí rompería ese patrón. Workflow dedicado toca solo `desempeno-hoy/data.json`.

**Trade-off conocido:** 96 commits/día solo a ese archivo. Si el ruido en el historial molesta, en Fase 2 movemos el JSON a un GCS bucket público o a un branch `data-live` desacoplado.

## Definición de "calificado"

Para cada `nid` con `fuente_id` en las 6 oficiales del país en `tabla_inmuebles_general`, el **timestamp de calificación** es la primera entrada cronológica del nid a `state_id IN (20, 63)` en:
- CO: `sellers-main-prod.co_rds_staging.habi_db_tabla_historico_estado_v2`
- MX: `sellers-main-prod.mx_rds_staging.habi_db_history_state`

Ese timestamp (UTC) se convierte a hora local del país (CO `-5`, MX `-6`, MX sin DST desde 2022) y se bucketea a hora 1-24 (hora 1 = `00:00-00:59`, hora 24 = `23:00-23:59`).

**Atribución de fuente:** la del lead al momento de su registro original (`tabla_inmuebles_general.fuente_id`), agrupada a 6 etiquetas:
- CO: WEB(3), Habimetro(7), Leadforms(47/37/41/42), CRM(20), Broker(39), Comercial(35)
- MX: WEB(3), Habimetro(7), Leadforms(47), Propiedades(46), Broker(39), Comercial(35)

Consistente con el WBR 2.0 y asignados-creacion.

**Filtro MM only:** las tablas `historico_estado_v2` (CO) y `habi_db_history_state` (MX) son log MM por construcción. Inmo vive en tablas `*_real_estate` aparte. Leer solo de las MM ya filtra MM.

## Query SQL (1 archivo, parametrizable)

`query.sql` recibe vía `bq query --parameter`:
- `pais` STRING (`'co'` o `'mx'`)
- `tz_offset` INT64 (`-5` o `-6`)
- referencias a tablas concretas vía `sed` en el workflow step

Estructura:

```sql
WITH lead_fuente AS (
  SELECT nid, fuente_id,
         CASE fuente_id
           WHEN 3 THEN 'WEB' WHEN 7 THEN 'Habimetro'
           WHEN 20 THEN 'CRM' WHEN 35 THEN 'Comercial'
           WHEN 39 THEN 'Broker' WHEN 46 THEN 'Propiedades'
           WHEN 47 THEN 'Leadforms' WHEN 37 THEN 'Leadforms'
           WHEN 41 THEN 'Leadforms' WHEN 42 THEN 'Leadforms'
         END AS fuente_label
  FROM <TIG_PAIS>
  WHERE fecha_creacion >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 DAY)
    AND nid IS NOT NULL
    AND fuente_id IN (3,7,20,35,37,39,41,42,46,47)
),
primer_calif AS (
  SELECT <ID_NEGOCIO_O_NID> AS nid,
         MIN(fecha_creacion) AS ts_calif_utc
  FROM <HISTORICO_PAIS>
  WHERE state_id IN (20, 63)
    AND fecha_creacion >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 40 DAY)
  GROUP BY 1
)
SELECT
  DATE(TIMESTAMP_ADD(p.ts_calif_utc, INTERVAL @tz_offset HOUR)) AS fecha_local,
  EXTRACT(HOUR FROM TIMESTAMP_ADD(p.ts_calif_utc, INTERVAL @tz_offset HOUR)) + 1 AS hora_1_24,
  f.fuente_label,
  COUNT(DISTINCT p.nid) AS calificados
FROM primer_calif p
JOIN lead_fuente f USING (nid)
WHERE f.fuente_label IS NOT NULL
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
```

**Notas de implementación:**
- MX: `habi_db_history_state` usa `deal_id` que mapea a `id_negocio` de TIG-MX. Hay que confirmar si `TIG-MX` ya tiene `nid` o si se necesita un JOIN intermedio con `habi_db_property_deal`. Si la columna `nid` existe en TIG-MX (sí existe, según `tablas_core.md`), usar directo.
- Ventana 40 días en `primer_calif` → cubre `today` + `prev_week` (-7d) + 4 mismos-días-de-semana **anteriores a prev_week** (-14d, -21d, -28d, -35d) + 5d de buffer por TZ.
- Ventana 60 días en `lead_fuente` → cubre leads creados antes de hoy que califican hoy.

## Shape del `data.json`

```json
{
  "generated_at_iso": "2026-05-19T14:32:01-05:00",
  "co": {
    "today_date": "2026-05-19",
    "today_weekday": 1,
    "sources": ["WEB","Habimetro","Leadforms","CRM","Broker","Comercial"],
    "by_hour": {
      "today":          { "WEB": [0,0,1,2,5,8, ..., null,null], "Habimetro": [...], ... },
      "prev_week":      { "WEB": [0,0,1,3,4,9, ..., 12,8], ... },
      "avg_4_weekdays": { "WEB": [0.2,0.5,1.0, ...], ... }
    },
    "totals": {
      "today_so_far":   { "WEB": 18, "Habimetro": 7, ..., "_all": 42 },
      "prev_week":      { "WEB": 95, ..., "_all": 280 },
      "avg_4_weekdays": { "WEB": 88.2, ..., "_all": 271.5 }
    }
  },
  "mx": { /* mismo shape */ }
}
```

**Decisiones:**
- Arrays de 24 posiciones, índice 0 = hora 1.
- `null` para horas futuras de `today` (Chart.js corta la línea).
- `prev_week`: el mismo día de la semana de hace 7 días (single, no promedio).
- `avg_4_weekdays`: media simple de los 4 mismos días de semana anteriores a `prev_week` (no incluye hoy ni la semana pasada). Sin filtros de outlier en V1.
- `_all` pre-agregado en `totals` → optimiza el caso "Todas" sin re-sumar client-side.
- Cuando hay subconjunto de fuentes seleccionado, el frontend suma client-side las activas.

## Layout del frontend

**Top → bottom:**

1. **Header (sticky):**
   - Back link "← Volver (Tableros Marketing Sellers)".
   - Título "Desempeño hoy · Calificados".
   - Subtítulo "Calificados MM (estados 20/63) — primer entrance — hora local del país".
   - Pill "Última actualización: hace X min" + botón ⟳ "Recargar".

2. **Selectors:**
   - País: chip-group CO / MX (single, default CO).
   - Vista: toggle "Acumulado" / "Por hora" (default Acumulado).
   - Fuentes: chips multi-select con las 6 etiquetas + atajo "Todas".

3. **KPI cards (4):**
   - Hoy hasta ahora (suma fuentes activas).
   - Mismo día sem. pasada (total día).
   - Promedio últimos 4 mismos días de semana (total día).
   - Hora actual: ritmo (calif/h) vs promedio de esa hora.

4. **Chart principal (Chart.js line):**
   - Eje X: 1-24, hora local del país. Guía vertical punteada en hora actual.
   - Eje Y: empieza en 0, escala automática.
   - 3 series:
     - **Hoy** — sólida `#818cf8`, grosor 3.
     - **Hace 7 días** — punteada `#94a3b8`, grosor 2.
     - **Prom. 4 últimos {weekday}** — punteada `#fbbf24`, grosor 2.
   - Tooltip por hora con valores de las 3 series + delta hoy vs prom.
   - Modo "Por hora": mismas 3 líneas pero sobre volumen, no acumulado.

5. **Footer:**
   - Nota fuente de datos + delay típico (30 min - 2h) + cadencia del workflow.

**Decisiones de diseño:**
- El comparativo aplica al **total filtrado**, no a una línea por fuente.
- Sin banda min-max sombreada.
- Sin meta del sheet OKR en V1.
- Eje Y se recalcula al cambiar de Acumulado a Por hora.

## Operacional

- **TZ:** hora local del país seleccionado, no del navegador. CO = UTC-5, MX = UTC-6 (sin DST).
- **Estados UI:** skeleton al cargar; "Sin datos" si el filtro deja todo vacío; banner "⚠ Datos retrasados" si `generated_at_iso` > 45 min atrás.
- **Workflow `desempeno-hoy.yml`:**
  - Cron `*/15 * * * *` UTC.
  - `concurrency: cancel-in-progress: true` para evitar acumulación.
  - Si la query falla, **no commit** — preservar el último JSON bueno.
  - Reusa secrets `GCP_CREDENTIALS` + `GCP_PROJECT`.
- **Botón ⟳ recargar:** cache-bust del fetch a `data.json?t=<ts>`. No dispara workflow.

## Conexión con el landing

Agregar `<a class="card">` al **final** de la sección "Tableros" en el `index.html` raíz (orden cronológico ascendente, ver `feedback_hub_orden`). Favicon megáfono igual que el resto.

## Verificación post-deploy

Antes de declarar éxito:
- Abrir `https://camotoya.github.io/tableros-marketing-habi/desempeno-hoy/` y validar que:
  - El chart muestra la línea de hoy con datos hasta cerca de la hora actual.
  - Las 2 series comparativas están completas (24 puntos).
  - El selector de país recalcula y los valores cambian.
  - Multi-select de fuentes recalcula KPIs y chart.
  - Toggle Acumulado/Por hora cambia el shape de las líneas.
  - El botón ⟳ recarga el JSON y actualiza el timestamp.
- Validar el delay real: la primera vez que aparezca un calificado del día, anotar hora real (en BQ) vs hora visible en el tablero.

## Riesgos / preguntas abiertas

- **Frescura real de las tablas operativas en BQ.** El delay típico de `historico_estado_v2` y `tabla_inmuebles_general` no está medido formalmente; se asume 30 min - 2h. Si el delay es mayor, el tablero pierde valor "live". → Mitigar mostrando el delay típico en el footer y validando empíricamente en la verificación.
- **Volumen de commits.** 96 commits/día solo a `data.json`. Trade-off aceptado en V1; Fase 2 mover a GCS si molesta.
- **MX `nid` en `habi_db_history_state`.** Confirmar al implementar si el JOIN directo `deal_id ↔ nid` funciona o requiere intermedio. Validable en 1 query de smoke test antes de armar el SQL final.
- **Fuente "Otro"** (fuente_id fuera de las 6 oficiales). Quedan excluidos en V1 (filtro `IN (...)` en la query). Si Marketing quiere verlos, los reincluimos con etiqueta "Otro".
