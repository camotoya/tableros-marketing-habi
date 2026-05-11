#!/usr/bin/env python3
"""
Builds asignados-filtros/data.json from the BQ JSON output of query.sql.

Usage:
  build_data.py <bq_query_output.json> <output_data.json>

Input shape (BQ --format=json): list of objects with string fields:
  {"d": "2026-05-10", "m": "8191", "c": "1", "f": "Habimetro", "n": "42"}

Output shape: see asignados-filtros/data.json structure in the spec.
"""
import json
import sys
from datetime import datetime, timezone


FILTERS = [
    {"id": "F3",  "bit": 0,  "group": "Correo",   "label": "Correo @habi.",
     "tooltip": "El correo del owner debe contener \"habi.\" (cubre @habi.co y @tuhabi.mx)."},
    {"id": "F4",  "bit": 1,  "group": "Correo",   "label": "Excluye agente/delta/call",
     "tooltip": "Excluye correos genéricos que contengan 'agente', 'delta' o 'call' (cuentas compartidas o roles automáticos)."},
    {"id": "F5",  "bit": 2,  "group": "Correo",   "label": "Excluye correos hardcoded",
     "tooltip": "Excluye alejandroaguirre@habi.co, erickcastillo@tuhabi.mx, victorialechtig@tuhabi.mx."},
    {"id": "F6",  "bit": 3,  "group": "Correo",   "label": "Owners especiales req. contacto digital",
     "tooltip": "4 correos (lauracruz, alejandrobravo, juanquinones, juanarcos @habi.co) solo cuentan si el lead tiene contacto_digital diligenciado."},
    {"id": "F7",  "bit": 4,  "group": "Estado",   "label": "Estado: sin pricing incial",
     "tooltip": "Acepta deals con estado 'sin pricing incial' (con typo, estado 63). Grupo Estado funciona como OR: deal pasa si su estado coincide con al menos uno de los marcados."},
    {"id": "F8",  "bit": 5,  "group": "Estado",   "label": "Estado: no gestionado",
     "tooltip": "Acepta deals con estado 'no gestionado'. Grupo Estado funciona como OR."},
    {"id": "F9",  "bit": 6,  "group": "Estado",   "label": "Estado: cierre",
     "tooltip": "Acepta deals con estado 'cierre'. Grupo Estado funciona como OR."},
    {"id": "F10", "bit": 7,  "group": "Estado",   "label": "Estado: no hay suficientes datos",
     "tooltip": "Acepta deals con estado 'no hay suficientes datos para comparar'. Grupo Estado funciona como OR."},
    {"id": "F11", "bit": 8,  "group": "Calidad",  "label": "Calificación ≠ N/NH",
     "tooltip": "La calificación del lead no puede ser 'N' ni 'NH' (case-insensitive)."},
    {"id": "F12", "bit": 9,  "group": "Inmueble", "label": "check_a_pricing = 1",
     "tooltip": "El inmueble debe haber pasado por pricing (check_a_pricing = 1)."},
    {"id": "F13", "bit": 10, "group": "Inmueble", "label": "fecha_creacion no nula",
     "tooltip": "El inmueble debe tener fecha de creación registrada."},
    {"id": "F14", "bit": 11, "group": "Inmueble", "label": "nid no nulo",
     "tooltip": "El inmueble debe existir (nid no nulo). Redundante con join pero expuesto para coherencia con el doc."},
    {"id": "F15", "bit": 12, "group": "Inmo",     "label": "Descarte a inmobiliaria",
     "tooltip": "[v1: dummy] La columna asignacion_descartes_top no es accesible. El toggle es funcional pero el filtro no excluye nada actualmente. Intento original: excluye leads asignados solo al canal inmobiliaria. Por aclarar con Data&BI cuál es la columna real."},
]


def main():
    if len(sys.argv) != 3:
        print("Usage: build_data.py <bq_query_output.json> <output_data.json>", file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, 'r', encoding='utf-8') as f:
        raw = json.load(f)

    fuentes_seen = set()
    rows = []
    for r in raw:
        # BQ returns all fields as strings in JSON format.
        d = r["d"]
        m = int(r["m"])
        c = int(r["c"])
        f_ = r["f"]
        n = int(r["n"])
        fuentes_seen.add(f_)
        rows.append({"d": d, "m": m, "c": c, "f": f_, "n": n})

    # Canonical fuente order matches the reference doc; "Otro" last.
    fuente_order = ["Habimetro", "CRM", "Broker", "WEB", "Ventanas", "Leadform", "Otro"]
    fuentes_out = [x for x in fuente_order if x in fuentes_seen]

    rows.sort(key=lambda r: (r["d"], r["m"], r["c"], r["f"]))

    out = {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
        "country": "CO",
        "filters": FILTERS,
        "fuentes": fuentes_out,
        "rows": rows,
    }

    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, separators=(',', ':'), ensure_ascii=False)

    print(f"wrote {out_path}: {len(rows)} rows, {len(fuentes_out)} fuentes", file=sys.stderr)


if __name__ == '__main__':
    main()
