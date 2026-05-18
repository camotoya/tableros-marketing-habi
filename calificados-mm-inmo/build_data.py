#!/usr/bin/env python3
"""
Builds calificados-mm-inmo/data.json from BQ query output.

Usage:
  build_data.py <bq_query_output.json> <output_data.json>

Input shape: list of {pais, d, fuente, calif_inmo, calif_mm, calif_both, reg}.
"""
import json
import sys
from datetime import datetime, timezone


FUENTE_ORDER = {
    "CO": ["WEB", "Leadforms", "Habimetro", "CRM", "Brokers", "Comercial"],
    "MX": ["WEB", "Leadforms", "Habimetro", "Propiedades", "Brokers", "Comercial"],
}


def main():
    if len(sys.argv) != 3:
        print("Usage: build_data.py <bq.json> <out.json>", file=sys.stderr)
        sys.exit(1)
    in_path, out_path = sys.argv[1], sys.argv[2]

    raw = json.load(open(in_path))
    fuentes_seen = {"CO": set(), "MX": set()}
    rows = []
    for r in raw:
        pais = r["pais"]
        fuente = r["fuente"]
        if pais in fuentes_seen and fuente:
            fuentes_seen[pais].add(fuente)
        rows.append({
            "pais":       pais,
            "d":          r["d"],
            "f":          fuente,
            "calif_inmo": int(r["calif_inmo"]),
            "calif_mm":   int(r["calif_mm"]),
            "calif_both": int(r["calif_both"]),
            "reg":        int(r["reg"]),
        })

    fuentes_out = {}
    for p, order in FUENTE_ORDER.items():
        seen = fuentes_seen.get(p, set())
        fuentes_out[p] = [x for x in order if x in seen] + sorted(seen - set(order))

    rows.sort(key=lambda r: (r["pais"], r["d"], r["f"]))

    out = {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
        "paises": ["CO", "MX"],
        "fuentes": fuentes_out,
        "rows": rows,
    }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(',', ':'), ensure_ascii=False)

    by_pais = {p: sum(1 for r in rows if r["pais"] == p) for p in ["CO", "MX"]}
    print(f"wrote {out_path}: {len(rows)} rows · {by_pais} · fuentes CO={fuentes_out['CO']} MX={fuentes_out['MX']}", file=sys.stderr)


if __name__ == "__main__":
    main()
