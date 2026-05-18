#!/usr/bin/env python3
"""
Builds asignados-creacion/data.json from BQ query output (CO + MX).

Usage:
  build_data.py <bq_query_output.json> <output_data.json>

Input shape: list of {"pais", "d", "f", "m"?, "bucket"?, "canal"?, "plataforma"?,
                     "spend"?, "clicks"?, "impressions"?, "series", "n"?}.
Series: 'mart' | 'ever' | 'gap' | 'leads_attr' | 'spend'.
"""
import json
import sys
from datetime import datetime, timezone


FUENTE_ORDER = {
    "CO": ["WEB", "Leadforms", "Habimetro", "CRM", "Brokers", "Comercial"],
    "MX": ["WEB", "Leadforms", "Habimetro", "Propiedades", "Brokers", "Comercial"],
}

# Plataformas core que se muestran primero. Otras se appendean al final ordenadas alfa.
PLATAFORMA_ORDER = ["Google", "Facebook", "Bing", "TikTok", "Instagram", "YouTube"]

# Canales core (orden por relevancia). El listado real se computa por país desde los datos.
CANAL_ORDER_HINT = [
    "WEB Paid", "Estudio Inmueble Paid", "lead_forms Paid",
    "WEB Blog", "Estudio Inmueble Blog",
    "WEB Community", "Estudio Inmueble Community",
    "WEB SAC", "Estudio Inmueble SAC",
    "WEB Referral",
]

# Filtros toggleables. 5 bits, todos semántica AND.
FILTERS = [
    {"id": "F7-F10", "bit": 0, "label": "Estado del deal en lista permitida",
     "estados": ["Sin pricing inicial", "No gestionado", "Cierre", "No hay suficientes datos para comparar"],
     "tooltip": "El estado actual del deal en HubSpot debe ser uno de: Sin pricing inicial, No gestionado, Cierre, No hay suficientes datos para comparar. Equivale al filtro IN (...) del mart sobre `estado`."},
    {"id": "F12",    "bit": 1, "label": "check_a_pricing = 1",
     "tooltip": "El inmueble pasó por pricing (check_a_pricing = 1)."},
    {"id": "F15",    "bit": 2, "label": "Sin descarte a inmobiliaria (proxy)",
     "tooltip": "tabla_inmuebles_general.inmobiliaria distinto de 1. Proxy del filtro F15 oficial (asignacion_descartes_top no accesible desde el workflow)."},
    {"id": "F3",     "bit": 3, "label": "Correo del owner contiene 'habi.'",
     "tooltip": "El correo del owner resuelto contiene 'habi.' (cubre @habi.co y @tuhabi.mx)."},
    {"id": "F11",    "bit": 4, "label": "Calificación ≠ N/NH",
     "tooltip": "calificacion_del_lead_v2 distinto de 'n' o 'nh' (case-insensitive)."},
]


def order_with_hint(items, hint):
    s = set(items)
    out = [x for x in hint if x in s]
    extras = sorted(s - set(hint))
    out.extend(extras)
    return out


def main():
    if len(sys.argv) != 3:
        print("Usage: build_data.py <bq_query_output.json> <output_data.json>", file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, 'r', encoding='utf-8') as f:
        raw = json.load(f)

    fuentes_seen   = {"CO": set(), "MX": set()}
    canales_seen   = {"CO": set(), "MX": set()}
    plataforms_seen = {"CO": set(), "MX": set()}

    mart_rows = []
    ever_rows = []
    gap_rows  = []
    leads_attr_rows = []
    spend_rows = []

    def _f(x):
        return float(x) if x is not None else 0.0

    for r in raw:
        pais = r["pais"]
        s = r["series"]
        f_ = r["f"]
        if f_ and pais in fuentes_seen:
            fuentes_seen[pais].add(f_)
        if s == "mart":
            mart_rows.append({"pais": pais, "d": r["d"], "f": f_, "n": int(r["n"])})
        elif s == "ever":
            ever_rows.append({"pais": pais, "d": r["d"], "f": f_, "m": int(r["m"]), "n": int(r["n"])})
        elif s == "gap":
            gap_rows.append({"pais": pais, "d": r["d"], "f": f_, "bucket": r["bucket"], "n": int(r["n"])})
        elif s == "leads_attr":
            canal = r["canal"]; plataforma = r["plataforma"]
            if canal:      canales_seen[pais].add(canal)
            if plataforma: plataforms_seen[pais].add(plataforma)
            leads_attr_rows.append({
                "pais": pais, "d": r["d"], "f": f_,
                "c": canal, "p": plataforma,
                "n": int(r["n"]),
            })
        elif s == "spend":
            canal = r["canal"]; plataforma = r["plataforma"]
            if canal:      canales_seen[pais].add(canal)
            if plataforma: plataforms_seen[pais].add(plataforma)
            spend_rows.append({
                "pais": pais, "d": r["d"], "f": f_,
                "c": canal, "p": plataforma,
                "s": _f(r.get("spend")),
                "k": _f(r.get("clicks")),
                "i": _f(r.get("impressions")),
            })

    fuentes_out = {}
    for p, order in FUENTE_ORDER.items():
        fuentes_out[p] = order_with_hint(fuentes_seen.get(p, set()), order)

    canales_out    = {p: order_with_hint(canales_seen[p],   CANAL_ORDER_HINT)    for p in ["CO", "MX"]}
    plataformas_out = {p: order_with_hint(plataforms_seen[p], PLATAFORMA_ORDER) for p in ["CO", "MX"]}

    mart_rows.sort(key=lambda r: (r["pais"], r["d"], r["f"]))
    ever_rows.sort(key=lambda r: (r["pais"], r["d"], r["f"], r["m"]))
    gap_rows.sort(key=lambda r: (r["pais"], r["d"], r["f"], r["bucket"]))
    leads_attr_rows.sort(key=lambda r: (r["pais"], r["d"], r["f"], r["c"] or "", r["p"] or ""))
    spend_rows.sort(key=lambda r: (r["pais"], r["d"], r["f"], r["c"] or "", r["p"] or ""))

    gap_band_order = ["F7-F10", "F12", "F15", "F3", "F11", "Otro"]

    out = {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
        "paises": ["CO", "MX"],
        "fuentes":     fuentes_out,
        "canales":     canales_out,
        "plataformas": plataformas_out,
        "filters": FILTERS,
        "gap_band_order": gap_band_order,
        "mart_rows": mart_rows,
        "ever_rows": ever_rows,
        "gap_rows":  gap_rows,
        "leads_attr_rows": leads_attr_rows,
        "spend_rows":      spend_rows,
    }

    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, separators=(',', ':'), ensure_ascii=False)

    summary = {
        p: {
            'mart': sum(1 for r in mart_rows if r['pais'] == p),
            'ever': sum(1 for r in ever_rows if r['pais'] == p),
            'gap':  sum(1 for r in gap_rows  if r['pais'] == p),
            'leads_attr': sum(1 for r in leads_attr_rows if r['pais'] == p),
            'spend':      sum(1 for r in spend_rows      if r['pais'] == p),
        } for p in ["CO", "MX"]
    }
    print(f"wrote {out_path}: CO {summary['CO']} · MX {summary['MX']}", file=sys.stderr)
    print(f"  canales CO={len(canales_out['CO'])} MX={len(canales_out['MX'])}", file=sys.stderr)
    print(f"  plataformas CO={len(plataformas_out['CO'])} MX={len(plataformas_out['MX'])}", file=sys.stderr)


if __name__ == '__main__':
    main()
