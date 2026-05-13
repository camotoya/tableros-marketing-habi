# Funnel por fuente de lead — diseño

**Fecha**: 2026-05-12
**Sub-tablero**: `funnel-fuentes/`
**Hub**: `tableros-marketing-habi`
**País**: Colombia (CO)
**Estado**: spec aprobado en alto nivel, pendiente plan de implementación

## 1. Motivación

Hoy no hay visibilidad clara del funnel completo desde landing hasta deal en CRM por **fuente de origen** del lead. En particular:

- Tráfico de `https://ayudaventas-habi-web.vercel.app/` se reparte en dos paths internos que terminan creando leads distintos en HubSpot, sin que el equipo pueda diferenciar volumen ni conversión etapa por etapa.
- El formulario "Inmo" hospedado directamente en la vercel no tiene pixel de Segment, por lo que el funnel para esa fuente es totalmente opaco (solo se ve el lead final).
- El formulario web puro de `habi.co/formulario-inmueble` tiene tracking detallado vía Segment pero no se ve cortado por origen UTM/referrer.

El tablero permite:
1. Comparar volumen y conversión etapa-a-etapa entre las tres fuentes.
2. Visualizar el blind spot del form Inmo en la vercel (filas en `—` hacen explícito el problema de tracking).
3. Detectar gap entre "formulario completado" y "deal existe en CRM" como señal de leakage.

## 2. Fuentes comparadas

| Fuente | Criterio técnico | Tracking de etapas |
|---|---|---|
| **Web habi.co (directo)** | Tráfico a `/formulario-inmueble/*` SIN `utm_content=help_to_sell` y SIN referrer `ayudaventas-habi-web.vercel.app` | Sí (Segment) |
| **Help-to-sell (redirect ayudaventas)** | Tráfico a `/formulario-inmueble/*` CON `utm_content=help_to_sell` O referrer `ayudaventas-habi-web.vercel.app` | Sí (Segment) |
| **Ayuda Venta (Inmo en vercel)** | `hubspot.deals.sub_fuente = 'Ayuda Venta'` | No (pixel no fira en vercel) |

## 3. Etapas del funnel (vista Funnel)

| # | Etapa | Path / criterio |
|---|---|---|
| 1 | Dirección | pageview en `/formulario-inmueble/direccion` |
| 2 | Zona | pageview en `/formulario-inmueble/inmuebles-zona` ∪ `/confirmar-ubicacion` ∪ `/sugerencias` |
| 3 | Datos inmueble | pageview en `/formulario-inmueble/datos-inmueble` |
| 4 | Contacto | pageview en `/formulario-inmueble/contacto` |
| 5 | Características | pageview en `/formulario-inmueble/caracteristicas` |
| 6 | Últimos detalles | pageview en `/formulario-inmueble/ultimos-detalles` |
| 7 | Felicitaciones | pageview en `/formulario-inmueble/felicitaciones` (form completado en el cliente) |
| 8 | Lead en HubSpot | deal existe vinculado al anonymous_id vía UUID chain (ver §4.2) |

**Métrica de cada celda (filas 1-7)**: `COUNT(DISTINCT anonymous_id)` que llegaron a esa etapa dentro de la ventana.

**Fila 8**: ver §4.

**Para fuente C (Ayuda Venta)**: filas 1-7 quedan en `—` con tooltip "sin tracking (pixel solo en habi.co)". Fila 8 se llena con conteo directo.

**Visualización por celda**: `count` grande + `% step→step` debajo en gris + heatmap rojo→verde sobre el `%` por fila.

## 4. Lógica de atribución a HubSpot (fila 8)

### 4.1. Fuente C (Ayuda Venta) — directa

```sql
SELECT COUNT(*) AS leads
FROM `sellers-main-prod.hubspot.deals`
WHERE sub_fuente = 'Ayuda Venta'
  AND DATE(createdate, 'America/Bogota') BETWEEN @start AND @end
```

### 4.2. Fuentes A y B (Web habi.co / Help-to-sell) — chain por UUID

Validado contra dos leads reales (NID 60055700571 con chain completo; NID 60173994780 con `b.uuid = NULL` = correcto, no usa el orquestador).

**Chain canónico** (dos UUIDs distintos en juego):

- `backbone_uuid` = UUID de la sesión web (lo emite `web_global_api_business` cuando se abre el form).
- `deal_uuid` = UUID del negocio en el OLTP (`habi_db_tabla_negocio_inmueble.uuid`).

```
segment.pages (anonymous_id)
  → segment.select_content (sc.anonymous_id, sc.backbone_uuid)          [puente anonymous_id ↔ sesión]
    → web_global_api_business (b.uuid = sc.backbone_uuid)               [puente sesión ↔ deal]
      → habi_db_tabla_negocio_inmueble (pd.uuid = b.deal_uuid)           [identidad del deal en OLTP]
        → tabla_inmuebles_general (g.nid = pd.nid)                       [vista analítica con fecha_creacion]
```

**Conteo**:

Para cada `anonymous_id` que hizo `/felicitaciones` en la ventana:
1. Obtener su `backbone_uuid` desde `select_content` (mismo anonymous_id, evento en la ventana).
2. Cruzar `web_global_api_business.uuid = backbone_uuid` para sacar el `deal_uuid` asociado.
3. Cruzar `habi_db_tabla_negocio_inmueble.uuid = deal_uuid` para obtener el `nid`.
4. Cruzar `tabla_inmuebles_general.nid` para obtener `fecha_creacion`.
5. Contar **solo si** `DATE(g.fecha_creacion, 'America/Bogota') ∈ ventana`.

Esto descarta automáticamente leads con `anonymous_id` repetido de visitas anteriores (cada sesión tiene su propio `backbone_uuid` y por tanto su propio `deal_uuid`).

**Métricas auxiliares (chips de diagnóstico al lado de fila 8)**:

- `completions_no_deal`: anonymous_ids que llegaron a `/felicitaciones` pero el chain no devolvió deal en la ventana. Posibles causas: bug del submit, deal cayó fuera de ventana, atribución vía otra fuente.
- (Reservado para investigación posterior): leads en HubSpot sin `/felicitaciones` previo → posible bot o ad-blocker.

**Nota de timezone**: Segment timestamps en UTC; `hubspot.deals.createdate` y `tabla_inmuebles_general.fecha_creacion` también. Conversión a `America/Bogota` (UTC-5) tanto para la ventana del usuario como para el match de día.

## 5. Vista Tendencia

**Gráfico de líneas**:
- Eje X: tiempo según selector D/W/M
- Eje Y: count de leads
- 3 series (1 por fuente) en colores distintos:
  - Web habi.co — azul
  - Help-to-sell — naranja
  - Ayuda Venta — verde

**Métrica primaria**: `Leads creados en HubSpot por período` (= fila 8 distribuida temporalmente).

**Toggle de capa secundaria**: mostrar `Form completions` (pageviews de `/felicitaciones`) como línea **punteada** del mismo color por fuente, para visualizar el gap completion→deal a lo largo del tiempo.

**Tabla resumen abajo del gráfico**:

| Fuente | Leads totales | Promedio/día | Mejor día | Form completions | Gap (com − leads) |
|---|---|---|---|---|---|

## 6. Controles de UI

Compartidos por las dos vistas:

- **Selector de ventana**: `7d` / `30d` / `90d` / Custom (date range).
- **Selector de granularidad**: `D` / `W` / `M` (afecta solo a Vista Tendencia).
- **Switch de vista**: `Funnel` | `Tendencia`.

## 7. Data — query y JSON

### 7.1. Shape del `data.json`

Granularidad atómica: un registro por día × fuente. Frontend agrega a la ventana seleccionada.

```json
{
  "generated_at": "2026-05-12T13:00:00Z",
  "tz": "America/Bogota",
  "lookback_days": 180,
  "daily": [
    {
      "date": "2026-05-06",
      "source": "web_puro",
      "stages": {
        "direccion": 3245,
        "zona": 412,
        "datos_inmueble": 380,
        "contacto": 350,
        "caracteristicas": 340,
        "ultimos_detalles": 320,
        "felicitaciones": 305,
        "lead_hubspot": 280
      },
      "completions_no_deal": 25
    },
    {
      "date": "2026-05-06",
      "source": "ayuda_venta",
      "stages": {
        "direccion": null,
        "zona": null,
        "datos_inmueble": null,
        "contacto": null,
        "caracteristicas": null,
        "ultimos_detalles": null,
        "felicitaciones": null,
        "lead_hubspot": 0
      },
      "completions_no_deal": null
    }
  ]
}
```

- Convenciones:
  - `null` = la fuente no tiene tracking para esa etapa (Ayuda Venta etapas 1-7).
  - `0` = la fuente sí trackea esa etapa pero el día no tuvo eventos.
- Tamaño estimado: 180 días × 3 fuentes × ~10 ints ≈ 40-60 KB.

### 7.2. SQL

Archivo: `funnel-fuentes/query.sql` (versionado en el repo, leído por el workflow).

Estructura por CTEs:

1. `pages_classified` — segment.pages filtrado a `/formulario-inmueble/*`, con CASE de fuente (web_puro vs help_to_sell). Solo CO segment.
2. `stages_daily` — agregación por `DATE(timestamp, 'America/Bogota')` × fuente × stage = `COUNT(DISTINCT anonymous_id)`. Genera filas 1-7 por día × fuente.
3. `uuid_chain` — join `pages → select_content → web_global_api_business → habi_db_tabla_negocio_inmueble → tabla_inmuebles_general` para asociar anonymous_id de `/felicitaciones` a un deal con su `fecha_creacion`.
4. `leads_ab_daily` — para cada fuente A/B: anonymous_ids con `/felicitaciones` que vincularon a un deal con `DATE(fecha_creacion, 'America/Bogota') = DATE(/felicitaciones timestamp, 'America/Bogota')` → conteo agrupado por día × fuente.
5. `leads_c_daily` — `hubspot.deals` con `sub_fuente = 'Ayuda Venta'` agrupado por `DATE(createdate, 'America/Bogota')`.
6. `completions_no_deal_daily` — anonymous_ids con `/felicitaciones` que NO matchearon a un deal vía chain (4.2), agrupado por día × fuente.
7. `final` — output relacional `(date, source, stage_name, count)`. Un script Python pivotea al shape JSON anidado.

Filtro temporal global: `DATE(timestamp / createdate / fecha_creacion, 'America/Bogota') >= CURRENT_DATE('America/Bogota') - INTERVAL 180 DAY` y `< CURRENT_DATE('America/Bogota')` (excluye día corriente, igual que el resto del hub).

### 7.3. Script de transformación

Archivo: `scripts/funnel_fuentes_to_json.py`

Input: salida de BQ en JSON (formato relacional plano).
Output: `funnel-fuentes/data.json` en el shape de §7.1.

Operaciones: pivotear filas a anidado por `(date, source) → stages → count`; preservar `null` vs `0`; agregar metadata (`generated_at`, `tz`, `lookback_days`).

## 8. Auto-update — integración al workflow consolidado

Agregar steps a `.github/workflows/update-data.yml` (no workflow separado — decisión documentada en `tableros/general.md`):

```yaml
- name: Funnel fuentes — query
  if: always()
  run: |
    bq query --use_legacy_sql=false --format=json --max_rows=10000 \
      < funnel-fuentes/query.sql > /tmp/funnel-fuentes-raw.json

- name: Funnel fuentes — transformar a shape final
  if: always()
  run: |
    python3 scripts/funnel_fuentes_to_json.py \
      /tmp/funnel-fuentes-raw.json \
      funnel-fuentes/data.json
```

Y agregar `funnel-fuentes/data.json` al `git add` del step de commit final.

Auth existente: `GCP_CREDENTIALS` con `papyrus-data` (acceso confirmado a todos los datasets del chain).

Cron existente: `0 13 * * *` UTC = 8:00 AM Colombia.

## 9. Landing card

Agregar al `index.html` del root:

```html
<a class="card" href="./funnel-fuentes/">
  <h3>Funnel por fuente de lead</h3>
  <p>Web habi.co · Help-to-sell · Ayuda Venta (Inmo) — etapas y conversión a HubSpot</p>
</a>
```

## 10. Frontend (`funnel-fuentes/index.html`)

- Standalone HTML con `<style>` inline (convención del hub: no CSS compartido).
- Back-link a `../` (estilo y texto: "← Volver (Tableros Marketing Sellers)").
- Favicon megáfono (convención).
- Tema visual compartido (paleta `#0f172a` / `#1e293b` / `#818cf8` / `#f8fafc` / …).
- Fetch a `./data.json` relativo.
- Filtrado y agregación en JS puro (sin dependencias backend).
- Chart de Tendencia: Chart.js vía CDN (consistente con WBR 2.0 / otros tableros).

Diseño visual de la tabla Funnel:
- Header row: nombres de las 3 fuentes.
- 8 filas: una por etapa con `count` + `% step→step` + heatmap por fila.
- Hover sobre celda muestra: count exacto, % desde inicio, % desde paso anterior.
- Tooltip sobre el `—` de Ayuda Venta: "sin tracking — pixel solo en habi.co".

## 11. Scope no incluido en esta iteración (follow-ups)

- **Investigación del Gap** (`completions_no_deal`): hipótesis de leakage del formulario. Pendiente review separado.
- **Pixel de Segment en `ayudaventas-habi-web.vercel.app`**: habilitaría tracking de pasos para fuente C — requiere intervención del equipo de tech.
- **Routing del form Inmo a la pipeline Inmo de HubSpot**: hoy `aplica_para_inmobiliaria = NULL` aunque el form se llame "Inmo" — bug independiente del tablero.
- **México**: ayudaventas no tiene tráfico MX hoy. Si se lanza ayudaventas-mx, replicar usando `mx_segment_profiles` y `papyrus-data-mx`.

## 12. Validación de supuestos (datos al 2026-05-12)

| Supuesto | Validado vía |
|---|---|
| Ayuda Venta solo aparece como `sub_fuente='Ayuda Venta'` en `hubspot.deals` | 2 leads históricos (2026-04-16, 2026-05-11) |
| Chain UUID funciona para leads del form web habi.co | NID 60055700571 (María Luz): chain completo, 7 page events |
| Chain UUID NO funciona para Ayuda Venta | NID 60173994780 (yajaira): `b.uuid = NULL`, 0 page events |
| Segment captura los 7 pasos canónicos del formulario en CO | 31,587 pageviews `/direccion` en 7 días, descenso natural hasta 1,440 `/felicitaciones` |
| MX no tiene tráfico de ayudaventas | 0 eventos en `mx_segment_profiles.pages` con esa URL/referrer |
