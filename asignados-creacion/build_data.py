#!/usr/bin/env python3
"""
Builds asignados-creacion/data.json from BQ query output (UNION ALL of mart_rows + ever_rows).

Usage:
  build_data.py <bq_query_output.json> <output_data.json>

Input shape: list of {"d", "f", "m" (nullable for mart), "series" ('mart'|'ever'), "n"}.
"""
import json
import sys
from datetime import datetime, timezone


FUENTE_ORDER = ["WEB", "Leadforms", "Habimetro", "CRM", "Brokers", "Comercial"]

# Filtros toggleables. 5 bits, todos semántica AND.
# F7-F10 está colapsado en un solo toggle compuesto (acepta cualquiera de los 4 estados permitidos).
FILTERS = [
    {"id": "F7-F10", "bit": 0, "label": "Estado del deal en lista permitida",
     "estados": ["Sin pricing incial", "No gestionado", "Cierre", "No hay suficientes datos para comparar"],
     "tooltip": "El estado actual del deal en HubSpot debe ser uno de: Sin pricing incial, No gestionado, Cierre, No hay suficientes datos para comparar. Equivale al filtro IN (...) del mart sobre `estado`."},
    {"id": "F12",    "bit": 1, "label": "check_a_pricing = 1",
     "tooltip": "El inmueble pasó por pricing (check_a_pricing = 1)."},
    {"id": "F15",    "bit": 2, "label": "Sin descarte a inmobiliaria (proxy)",
     "tooltip": "tabla_inmuebles_general.inmobiliaria distinto de 1. Proxy del filtro F15 oficial (asignacion_descartes_top no accesible desde el workflow)."},
    {"id": "F3",     "bit": 3, "label": "Correo del owner contiene 'habi.'",
     "tooltip": "El correo del owner resuelto contiene 'habi.' (cubre @habi.co y @tuhabi.mx)."},
    {"id": "F11",    "bit": 4, "label": "Calificación ≠ N/NH",
     "tooltip": "calificacion_del_lead_v2 distinto de 'n' o 'nh' (case-insensitive)."},
]


def main():
    if len(sys.argv) != 3:
        print("Usage: build_data.py <bq_query_output.json> <output_data.json>", file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, 'r', encoding='utf-8') as f:
        raw = json.load(f)

    fuentes_seen = set()
    mart_rows = []
    ever_rows = []
    gap_rows  = []
    for r in raw:
        f_ = r["f"]
        fuentes_seen.add(f_)
        s = r["series"]
        if s == "mart":
            mart_rows.append({"d": r["d"], "f": f_, "n": int(r["n"])})
        elif s == "ever":
            ever_rows.append({"d": r["d"], "f": f_, "m": int(r["m"]), "n": int(r["n"])})
        elif s == "gap":
            gap_rows.append({"d": r["d"], "f": f_, "bucket": r["bucket"], "n": int(r["n"])})

    fuentes_out = [x for x in FUENTE_ORDER if x in fuentes_seen]
    extras = sorted(fuentes_seen - set(FUENTE_ORDER))
    fuentes_out.extend(extras)

    mart_rows.sort(key=lambda r: (r["d"], r["f"]))
    ever_rows.sort(key=lambda r: (r["d"], r["f"], r["m"]))
    gap_rows.sort(key=lambda r: (r["d"], r["f"], r["bucket"]))

    # Orden de bandas para el stacked area (de mayor a menor impacto + Otro al final)
    gap_band_order = ["F7-F10", "F12", "F15", "F3", "F11", "Otro"]

    out = {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
        "country": "CO",
        "fuentes": fuentes_out,
        "filters": FILTERS,
        "gap_band_order": gap_band_order,
        "mart_rows": mart_rows,
        "ever_rows": ever_rows,
        "gap_rows":  gap_rows,
    }

    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, separators=(',', ':'), ensure_ascii=False)

    print(f"wrote {out_path}: {len(mart_rows)} mart + {len(ever_rows)} ever + {len(gap_rows)} gap, {len(fuentes_out)} fuentes", file=sys.stderr)


if __name__ == '__main__':
    main()
